-- | Orchestrate a native build: drive the Canopy compiler to IIFE JS, wrap it into a
-- Hermes bundle, and emit the Fabric mapping glue. The tool shells out to the existing
-- @canopy@ compiler (feasibility report §1: "ship the JS it already produces") — it
-- does not reimplement compilation.
module Canopy.Native.Build
  ( BuildOptions (..)
  , runBuild
  , findCanopy
  , writeCodegen
  ) where

import           Canopy.Native.Assets
import           Canopy.Native.Autolink (discoverPackages, hostAndroidFromEnv, writeAndroidAutolink)
import           Canopy.Native.Bundle
import           Canopy.Native.Codegen
import           Canopy.Native.Component (defaultComponents)
import           Canopy.Native.Config
import qualified Data.Aeson as Aeson
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as BL
import           Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import qualified Data.Text.Lazy as TL
import qualified Data.Text.Lazy.Encoding as TLE
import           System.Directory
import           System.Environment (lookupEnv)
import           System.Exit (ExitCode (..))
import           System.FilePath ((</>), takeFileName)
import           System.Process (readCreateProcessWithExitCode, proc, cwd)

-- | Inputs to a build.
data BuildOptions = BuildOptions
  { boProjectDir :: !FilePath  -- ^ directory holding native.config.json + canopy.json
  , boRelease    :: !Bool      -- ^ pass @--optimize@ to the compiler
  } deriving (Eq, Show)

-- | Run the full pipeline, returning the bundle path on success.
runBuild :: BuildOptions -> IO (Either Text FilePath)
runBuild opts = do
  cfgResult <- loadConfig (boProjectDir opts)
  either (pure . Left) (buildWithConfig opts) cfgResult

-- | Load + parse native.config.json from the project directory.
loadConfig :: FilePath -> IO (Either Text NativeConfig)
loadConfig dir = do
  let path = dir </> "native.config.json"
  exists <- doesFileExist path
  if not exists
    then pure (Left (T.pack ("missing " <> path <> " (run `canopy-native init` first)")))
    else either (Left . T.pack) Right . decodeConfig <$> BL.readFile path

buildWithConfig :: BuildOptions -> NativeConfig -> IO (Either Text FilePath)
buildWithConfig opts cfg = do
  canopy <- findCanopy
  case canopy of
    Nothing  -> pure (Left canopyMissingHint)
    Just bin -> compileAndBundle opts cfg bin

compileAndBundle :: BuildOptions -> NativeConfig -> FilePath -> IO (Either Text FilePath)
compileAndBundle opts cfg bin = do
  let dir       = boProjectDir opts
      relOut    = ncOutputDir cfg </> "app.iife.js"  -- cwd-relative for `canopy make`
      absOutDir = dir </> ncOutputDir cfg
      absOut    = dir </> relOut
  createDirectoryIfMissing True absOutDir
  code <- runCanopyMake bin dir (ncEntry cfg) relOut (boRelease opts)
  case code of
    Left err -> pure (Left err)
    Right () -> finishBundle cfg dir absOutDir absOut

-- | Invoke @canopy make <entry> --output=<iife> --output-format=iife [--optimize]@.
runCanopyMake :: FilePath -> FilePath -> FilePath -> FilePath -> Bool -> IO (Either Text ())
runCanopyMake bin dir entry out release = do
  let args = [ "make", entry, "--output=" <> out, "--output-format=iife" ]
             ++ [ "--optimize" | release ]
  (ec, _so, se) <- readCreateProcessWithExitCode (proc bin args) { cwd = Just dir } ""
  pure $ case ec of
    ExitSuccess   -> Right ()
    ExitFailure n -> Left (T.pack ("canopy make failed (exit " <> show n <> "):\n" <> se))

-- | Wrap the compiled IIFE into a Hermes bundle, write the codegen artifacts + content-addressed
-- manifest, and (when CANOPY_HOST_ASSETS is set) deploy into the host's assets dir.
finishBundle :: NativeConfig -> FilePath -> FilePath -> FilePath -> IO (Either Text FilePath)
finishBundle cfg dir outDir iife = do
  produced <- doesFileExist iife
  if not produced
    then pure (Left (T.pack ("compiler did not produce " <> iife)))
    else do
      compiledRaw <- TIO.readFile iife
      -- Re-align the compiler's source map to the assembled bundle (it emits one in dev mode;
      -- --optimize emits none). The preamble shift is exact, so a JS error stack symbolicates
      -- straight to `.can` positions.
      let iifeMap = iife <> ".map"
      hasMap <- doesFileExist iifeMap
      mShifted <- if hasMap
                    then Just . shiftSourceMap compiledLineOffset <$> TIO.readFile iifeMap
                    else pure Nothing
      let compiled   = stripSourceMapRef compiledRaw  -- drop the compiler's app.iife.js.map ref
          bundlePath = outDir </> "canopy.bundle.js"
          mapPath    = outDir </> "canopy.bundle.js.map"
          -- Bare Hermes can't fetch the sibling .map, so in dev we ALSO carry it in-bundle as
          -- a global the runtime's __canopy_symbolicate reads to point the red-box at .can src.
          embed = case mShifted of
                    Just m  -> "globalThis.__canopy_sourcemap = " <> jsonStringLit m <> ";\n"
                    Nothing -> ""
          bundle = assembleBundle (BundleInputs compiled (ncMainModule cfg))
                     <> embed
                     <> "//# sourceMappingURL=canopy.bundle.js.map\n"
      TIO.writeFile bundlePath bundle
      maybe (pure ()) (TIO.writeFile mapPath) mShifted
      writeCodegen (outDir </> "generated")
      -- Content-addressed manifest: bundle sha256 (= buildId) + asset shas + runtimeVersion.
      manifest <- buildManifest cfg dir bundlePath
      BL.writeFile (outDir </> "canopy.manifest.json") (renderManifest manifest)
      deployArtifacts cfg dir outDir
      runAutolink dir
      pure (Right bundlePath)

-- | Autolink step: when a host Android dir is resolvable (CANOPY_HOST_ANDROID, or derived from
-- CANOPY_HOST_ASSETS), scan the app's dependency graph for packages that declare native modules
-- and (re)generate the registrant + Gradle fragment into the host tree. A no-op otherwise — the
-- host's @#if __has_include@ guard means an un-autolinked checkout still compiles.
runAutolink :: FilePath -> IO ()
runAutolink appDir = do
  mHost <- hostAndroidFromEnv
  case mHost of
    Nothing   -> pure ()
    Just host -> do
      pkgs <- discoverPackages appDir
      writeAndroidAutolink host pkgs
      let names = [ T.pack (show (length pkgs)) ]
      TIO.putStrLn (T.concat (["autolinked "] ++ names ++ [" package(s) with native modules -> ", T.pack host]))

-- | Build the manifest: sha256 the assembled bundle (the buildId / content address) + every
-- declared asset, stamped with the config's runtimeVersion.
buildManifest :: NativeConfig -> FilePath -> FilePath -> IO AssetManifest
buildManifest cfg dir bundlePath = do
  bytes <- BS.readFile bundlePath
  let buildId     = sha256Hex bytes
      bundleEntry = AssetEntry (T.pack "canopy.bundle.js") buildId (fromIntegral (BS.length bytes))
  assets <- collectAssets (map (dir </>) (ncAssets cfg))
  pure (AssetManifest bundleEntry assets (ncRuntimeVersion cfg) buildId)

-- | When CANOPY_HOST_ASSETS points at a host assets dir, copy the bundle + map + manifest +
-- declared assets there, skipping any file whose bytes already match. Kills the hand-`cp`
-- footgun + needless asset churn. A no-op when the env var is unset.
deployArtifacts :: NativeConfig -> FilePath -> FilePath -> IO ()
deployArtifacts cfg dir outDir = do
  mDest <- lookupEnv "CANOPY_HOST_ASSETS"
  case mDest of
    Nothing -> pure ()
    Just dest -> do
      createDirectoryIfMissing True dest
      let srcs = [ outDir </> "canopy.bundle.js"
                 , outDir </> "canopy.bundle.js.map"
                 , outDir </> "canopy.manifest.json"
                 ] ++ map (dir </>) (ncAssets cfg)
      mapM_ (copyIfChanged dest) srcs

-- | Copy @src@ into @destDir@ (by basename) unless an identical file is already there.
copyIfChanged :: FilePath -> FilePath -> IO ()
copyIfChanged destDir src = do
  exists <- doesFileExist src
  if not exists
    then pure ()
    else do
      let dst = destDir </> takeFileName src
      dstExists <- doesFileExist dst
      same <- if dstExists then (==) <$> BS.readFile src <*> BS.readFile dst else pure False
      if same then pure () else copyFile src dst

-- | Encode a 'Text' as a JSON string literal (valid JS), used to embed the source map as
-- a @globalThis.__canopy_sourcemap@ string the runtime JSON.parses.
jsonStringLit :: Text -> Text
jsonStringLit = TL.toStrict . TLE.decodeUtf8 . Aeson.encode

-- | Write the three generated mapping files (JSON / C++ / TS) from the component set.
writeCodegen :: FilePath -> IO ()
writeCodegen dir = do
  createDirectoryIfMissing True dir
  BL.writeFile  (dir </> "component-manifest.json") (renderManifestJSON defaultComponents)
  TIO.writeFile (dir </> "CanopyComponents.h")      (renderCppHeader defaultComponents)
  TIO.writeFile (dir </> "canopyComponents.ts")     (renderTypeScript defaultComponents)

-- | Locate the @canopy@ compiler binary: PATH first, then the conventional install
-- spots the compiler's README documents.
findCanopy :: IO (Maybe FilePath)
findCanopy = do
  onPath <- findExecutable "canopy"
  case onPath of
    Just p  -> pure (Just p)
    Nothing -> firstExisting =<< candidatePaths

candidatePaths :: IO [FilePath]
candidatePaths = do
  home <- getHomeDirectory
  pure [ home </> ".local" </> "bin" </> "canopy" ]

firstExisting :: [FilePath] -> IO (Maybe FilePath)
firstExisting [] = pure Nothing
firstExisting (p : rest) = do
  ok <- doesFileExist p
  if ok then pure (Just p) else firstExisting rest

canopyMissingHint :: Text
canopyMissingHint = T.unlines
  [ "could not find the `canopy` compiler on PATH or in ~/.local/bin."
  , "Build + install it once:"
  , "    cd ~/projects/canopy/compiler && make build"
  , "    cp $(stack path --local-install-root)/bin/canopy ~/.local/bin/canopy"
  ]

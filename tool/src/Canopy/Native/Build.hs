-- | Orchestrate a native build: drive the Canopy compiler to IIFE JS, wrap it into a
-- Hermes bundle, and emit the Fabric mapping glue. The tool shells out to the existing
-- @canopy@ compiler (feasibility report §1: "ship the JS it already produces") — it
-- does not reimplement compilation.
module Canopy.Native.Build
  ( BuildOptions (..)
  , runBuild
  , findCanopy
  , writeCodegen
    -- * AND-10 release-map archival (exported for unit tests)
  , archiveReleaseMap
  , buildManifest
  ) where

import           Canopy.Native.Assets
import           Canopy.Native.Autolink (discoverPackages, hostAndroidFromEnv, hostIosFromEnv, writeAndroidAutolink, writeIosAutolink)
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
    Right () -> do
      -- AND-10: the --optimize (Prod) compile emits NO source map, so an obfuscated
      -- release crash is unreadable. To archive a buildId-keyed map even for a release
      -- build, do a SECOND, dev-mode compile to a sibling path (app.iife.dev.js[.map]).
      -- That dev map is then aligned to the bundle preamble and archived alongside the
      -- (lean, map-less) release bundle. The release bundle itself stays unchanged.
      mArchive <- if boRelease opts
                    then compileArchiveMap bin cfg dir
                    else pure Nothing
      finishBundle cfg dir absOutDir absOut mArchive

-- | AND-10 release-map archival: run a second compile WITHOUT @--optimize@ so the compiler
-- emits a dev-mode @.map@ (Prod emits none), then hand back the aligned-and-shifted map text
-- so 'finishBundle' can write it as a buildId-keyed archive artifact. The dev IIFE itself is a
-- throwaway sibling (@app.iife.dev.js@); only its map matters here. Returns 'Nothing' (a no-op,
-- non-fatal) if the dev compile fails or the compiler still emitted no map — the release build
-- must not break just because map archival could not run.
compileArchiveMap :: FilePath -> NativeConfig -> FilePath -> IO (Maybe Text)
compileArchiveMap bin cfg dir = do
  let relDev = ncOutputDir cfg </> "app.iife.dev.js"   -- cwd-relative for `canopy make`
      absDev = dir </> relDev
  code <- runCanopyMake bin dir (ncEntry cfg) relDev False  -- dev mode => emits .map
  case code of
    Left _   -> pure Nothing   -- non-fatal: archival is best-effort, never fails the release
    Right () -> do
      let devMap = absDev <> ".map"
      hasMap <- doesFileExist devMap
      mAligned <- if not hasMap
                    then pure Nothing
                    else Just . shiftSourceMap compiledLineOffset <$> TIO.readFile devMap
      -- The dev IIFE + its raw map are throwaway scaffolding for the archive map; remove them
      -- so the release output dir carries only the lean bundle + the buildId-keyed archive.
      removeFileIfExists absDev
      removeFileIfExists devMap
      pure mAligned

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
-- manifest, and (when CANOPY_HOST_ASSETS is set) deploy into the host's assets dir. The optional
-- @mArchiveMap@ (AND-10) is a preamble-aligned source map captured from a SECOND dev-mode compile
-- of a release build; it is archived under a buildId-keyed name so an obfuscated production crash
-- can be retraced offline, without bloating the lean release bundle.
finishBundle :: NativeConfig -> FilePath -> FilePath -> FilePath -> Maybe Text -> IO (Either Text FilePath)
finishBundle cfg dir outDir iife mArchiveMap = do
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
      -- AND-10: archive the (release) source map keyed to the bundle's content address so a
      -- future obfuscated crash carrying that buildId selects the exact map. The buildId IS the
      -- assembled bundle's sha256, so name + hash it here, then fold it into the manifest assets.
      mArchiveEntry <- archiveReleaseMap outDir bundlePath mArchiveMap
      -- Content-addressed manifest: bundle sha256 (= buildId) + asset shas + runtimeVersion +
      -- (release) the archived buildId-keyed map.
      manifest <- buildManifest cfg dir bundlePath mArchiveEntry
      BL.writeFile (outDir </> "canopy.manifest.json") (renderManifest manifest)
      deployArtifacts cfg dir outDir
      runAutolink dir
      pure (Right bundlePath)

-- | AND-10: write the preamble-aligned archive map under a buildId-keyed name
-- (@canopy.<buildId>.map@) next to the bundle, and return its 'AssetEntry' (sha256 + size + name)
-- so the manifest records it. The buildId is the bundle's sha256 — the SAME content address a
-- crash report carries — so retrace tooling can pick the exact map for a given build. A no-op
-- (returns 'Nothing') for a dev build or when no archive map was captured.
archiveReleaseMap :: FilePath -> FilePath -> Maybe Text -> IO (Maybe AssetEntry)
archiveReleaseMap _      _          Nothing    = pure Nothing
archiveReleaseMap outDir bundlePath (Just mapTxt) = do
  bundleBytes <- BS.readFile bundlePath
  let buildId      = sha256Hex bundleBytes
      archiveName  = "canopy." <> T.unpack buildId <> ".map"
      archivePath  = outDir </> archiveName
  TIO.writeFile archivePath mapTxt
  fileEntry archivePath

-- | Autolink step: when a host Android dir is resolvable (CANOPY_HOST_ANDROID, or derived from
-- CANOPY_HOST_ASSETS), scan the app's dependency graph for packages that declare native modules
-- and (re)generate the registrant + Gradle fragment into the host tree. A no-op otherwise — the
-- host's @#if __has_include@ guard means an un-autolinked checkout still compiles.
runAutolink :: FilePath -> IO ()
runAutolink appDir = do
  -- Discover ONCE, feed every host writer the same package set.
  pkgs <- discoverPackages appDir
  let count = T.pack (show (length pkgs))
  -- Android host (CANOPY_HOST_ANDROID, or derived from CANOPY_HOST_ASSETS).
  mAndroid <- hostAndroidFromEnv
  case mAndroid of
    Nothing   -> pure ()
    Just host -> do
      writeAndroidAutolink host pkgs
      TIO.putStrLn (T.concat ["autolinked ", count, " package(s) with native modules -> ", T.pack host])
  -- iOS host (CANOPY_HOST_IOS) — independent + additive; the host's __has_include guard means an
  -- un-autolinked checkout still compiles, and re-registering a name is benign (registry replaces).
  mIos <- hostIosFromEnv
  case mIos of
    Nothing  -> pure ()
    Just ios -> do
      writeIosAutolink ios pkgs
      TIO.putStrLn (T.concat ["autolinked ", count, " package(s) with native modules -> ", T.pack ios])

-- | Build the manifest: sha256 the assembled bundle (the buildId / content address) + every
-- declared asset, stamped with the config's runtimeVersion. AND-10: a release build also folds
-- the buildId-keyed archived source map into the asset list (its @name@ is @canopy.<buildId>.map@),
-- so a crash report's buildId selects the exact map; the bundle's own sha256 is that buildId.
buildManifest :: NativeConfig -> FilePath -> FilePath -> Maybe AssetEntry -> IO AssetManifest
buildManifest cfg dir bundlePath mArchiveEntry = do
  bytes <- BS.readFile bundlePath
  let buildId     = sha256Hex bytes
      bundleEntry = AssetEntry (T.pack "canopy.bundle.js") buildId (fromIntegral (BS.length bytes))
  declared <- collectAssets (map (dir </>) (ncAssets cfg))
  let assets = declared ++ maybe [] (: []) mArchiveEntry
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

-- | Remove a file if it exists; a no-op otherwise (used to clean up the throwaway dev IIFE
-- produced only to capture the archive source map under @--release@).
removeFileIfExists :: FilePath -> IO ()
removeFileIfExists p = do
  exists <- doesFileExist p
  if exists then removeFile p else pure ()

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

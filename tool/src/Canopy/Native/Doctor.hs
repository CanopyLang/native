-- | @canopy-native doctor@ — report which parts of the native toolchain are present,
-- so a fresh machine knows exactly what to install before it can build/run on device.
module Canopy.Native.Doctor
  ( Check (..)
  , runChecks
  , renderChecks
  ) where

import           Data.Maybe (isJust)
import           Data.Text (Text)
import qualified Data.Text as T
import           System.Directory (findExecutable, getHomeDirectory, doesFileExist)
import           System.Environment (lookupEnv)
import           System.FilePath ((</>))

-- | One toolchain probe and its verdict.
data Check = Check
  { checkName   :: !Text
  , checkOk     :: !Bool
  , checkDetail :: !Text
  , checkNeeded :: !Text  -- ^ what it unlocks ("required" / "iOS device builds" …)
  } deriving (Eq, Show)

-- | Run every probe.
runChecks :: IO [Check]
runChecks =
  sequence
    [ exeCheck "canopy"   "the Canopy compiler"        "required (compile to JS)" canopyExtra
    , exeCheck "node"     "Node.js"                    "required (host tooling)"  noExtra
    , exeCheck "npx"      "npx"                        "required (RN host)"       noExtra
    , exeCheck "java"     "JDK"                        "Android builds"           noExtra
    , androidCheck
    , exeCheck "adb"      "Android platform tools"     "Android device installs"  noExtra
    , exeCheck "xcodebuild" "Xcode"                    "iOS builds (macOS only)"  noExtra
    , exeCheck "pod"      "CocoaPods"                  "iOS dependency install"   noExtra
    ]
  where
    noExtra = pure T.empty

-- | A check that passes iff an executable is on PATH.
exeCheck :: String -> Text -> Text -> IO Text -> IO Check
exeCheck exe label needed extra = do
  found <- findExecutable exe
  detail <- maybe extra (pure . T.pack) found
  pure (Check label (isJust found) detail needed)

-- canopy may live in ~/.local/bin without being on PATH; note that.
canopyExtra :: IO Text
canopyExtra = do
  home <- getHomeDirectory
  let p = home </> ".local" </> "bin" </> "canopy"
  there <- doesFileExist p
  pure (if there then T.pack (p <> " (not on PATH)") else "not found — run `make build` in compiler/")

-- | Android needs an SDK location more than a single binary.
androidCheck :: IO Check
androidCheck = do
  sdk <- firstEnv [ "ANDROID_HOME", "ANDROID_SDK_ROOT" ]
  pure $ case sdk of
    Just (var, path) -> Check "Android SDK" True (T.pack (var <> "=" <> path)) "Android builds"
    Nothing          -> Check "Android SDK" False "ANDROID_HOME / ANDROID_SDK_ROOT unset" "Android builds"

firstEnv :: [String] -> IO (Maybe (String, String))
firstEnv [] = pure Nothing
firstEnv (v : rest) = do
  mv <- lookupEnv v
  case mv of
    Just val | not (null val) -> pure (Just (v, val))
    _                         -> firstEnv rest

-- | Render the checks as an aligned report.
renderChecks :: [Check] -> Text
renderChecks checks =
  T.unlines (header : map row checks ++ [footer])
  where
    header = "  toolchain                what it unlocks"
    footer = let n = length (filter checkOk checks)
             in "\n  " <> T.pack (show n) <> "/" <> T.pack (show (length checks))
                <> " present. Missing items are only needed for the platforms they name."
    row c =
      T.concat
        [ "  ", tick (checkOk c), " "
        , pad 22 (checkName c), pad 28 (checkNeeded c)
        , checkDetail c ]
    tick True  = "\x2713"
    tick False = "\x2717"
    pad n t = let s = T.take n t in s <> T.replicate (max 1 (n - T.length s)) " "

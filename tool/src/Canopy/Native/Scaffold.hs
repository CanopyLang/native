-- | @canopy-native init@ — scaffold a fresh native app project (canopy.json,
-- native.config.json, a starter @Main.can@). Mirrors the counter example.
module Canopy.Native.Scaffold
  ( scaffoldApp
  ) where

import           Canopy.Native.Config
import qualified Data.ByteString.Lazy as BL
import           Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import           System.Directory (createDirectoryIfMissing, doesPathExist)
import           System.FilePath ((</>))

-- | Create @dir@ with a runnable starter app named @name@ (bundle id @bundleId@).
-- Refuses to overwrite an existing non-empty target.
scaffoldApp :: FilePath -> Text -> Text -> IO (Either Text ())
scaffoldApp dir name bundleId = do
  clash <- doesPathExist (dir </> "native.config.json")
  if clash
    then pure (Left (T.pack (dir <> " already contains a native.config.json")))
    else do
      createDirectoryIfMissing True (dir </> "src")
      BL.writeFile  (dir </> "native.config.json") (encodeConfig (defaultConfig name bundleId))
      TIO.writeFile (dir </> "canopy.json")         (appOutline name)
      TIO.writeFile (dir </> "src" </> "Main.can")  starterMain
      TIO.writeFile (dir </> "README.md")           (readme name)
      pure (Right ())

appOutline :: Text -> Text
appOutline _ = T.unlines
  [ "{"
  , "    \"type\": \"application\","
  , "    \"canopy-version\": \"0.19.1\","
  , "    \"source-directories\": [ \"src\" ],"
  , "    \"dependencies\": {"
  , "        \"direct\": {"
  , "            \"canopy/core\": \"1.0.0\","
  , "            \"canopy/json\": \"1.0.0\","
  , "            \"canopy/native\": \"0.1.0\","
  , "            \"canopy/virtual-dom\": \"1.0.0\""
  , "        },"
  , "        \"indirect\": {}"
  , "    },"
  , "    \"test-dependencies\": { \"direct\": {}, \"indirect\": {} }"
  , "}"
  ]

starterMain :: Text
starterMain = T.unlines
  [ "module Main exposing (main)"
  , ""
  , "import Native"
  , "import Native.Attributes as A"
  , "import Native.Events as Events"
  , ""
  , "type alias Model = Int"
  , ""
  , "type Msg = Increment"
  , ""
  , "init : () -> ( Model, Cmd Msg )"
  , "init _ = ( 0, Cmd.none )"
  , ""
  , "update : Msg -> Model -> ( Model, Cmd Msg )"
  , "update Increment model = ( model + 1, Cmd.none )"
  , ""
  , "view : Model -> Native.Node Msg"
  , "view model ="
  , "    Native.column [ A.padding 24, A.flex 1, A.justifyContent \"center\" ]"
  , "        [ Native.text [ A.fontSize 28 ] (\"Count: \" ++ String.fromInt model)"
  , "        , Native.button [ Events.onPress Increment, A.testID \"increment\" ] \"Tap me\""
  , "        ]"
  , ""
  , "main : Native.Program () Model Msg"
  , "main ="
  , "    Native.element"
  , "        { init = init, view = view, update = update, subscriptions = always Sub.none }"
  ]

readme :: Text -> Text
readme name = T.unlines
  [ "# " <> name
  , ""
  , "A canopy/native app. Build it with:"
  , ""
  , "    canopy-native build"
  , ""
  , "Then host the produced `build/canopy.bundle.js` with the React Native shell in"
  , "`canopy/native/host` (see that directory's README)."
  ]

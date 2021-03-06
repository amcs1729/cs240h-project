-- | Run ParseIni as a web server
{-# LANGUAGE OverloadedStrings #-}
module Main where

import ParseIni
import PrettyPrintIni

import Data.ByteString.Builder
import qualified Data.ByteString.Char8 as B
import qualified Data.ByteString.Lazy.Char8 as BL
import Data.List (foldl', intersperse)
import qualified Data.Map.Strict as M
import Data.Monoid
import Data.Text.Encoding (decodeUtf8, encodeUtf8)
import qualified Data.Text.Lazy as T
import qualified Data.Text.Lazy.Encoding as TE
import Happstack.Lite
import Language.Haskell.Interpreter as HaskellInterpreter
import qualified Sound.Tidal.Context as Tidal
import qualified Sound.Tidal.Stream as TidalStream
import Text.Blaze.Html (ToMarkup)
import Text.Blaze.Html5 ((!))
import qualified Text.Blaze.Html5 as H
import qualified Text.Blaze.Html5.Attributes as A

type OscPattern = Tidal.Pattern TidalStream.OscMap

-- *** HTML Generating functions *** --

-- |Take some HTML and put it in a monospaced blockquote.
monoBlock :: ToMarkup a => a -> H.Html
monoBlock = (H.blockquote ! A.style "font-family:monospace;") . H.pre . H.toHtml

-- |Equivalent of @<br clear="all"/>@ from days of yore.
brClear :: H.Html
brClear = H.br ! A.style "clear:both;"

-- |A skeleton HTML response.
pageSkeleton :: H.Html -> H.Html
pageSkeleton contents = H.docTypeHtml $ do
    H.head $ do
        H.title "Stanford CS240h Lab 2 Oracle"
        H.link ! A.rel "stylesheet" ! A.type_ "text/css"
               ! A.href "http://netdna.bootstrapcdn.com/bootstrap/3.1.1/css/bootstrap.min.css"
        H.link ! A.rel "shortcut icon" ! A.href "http://www.scs.stanford.edu/favicon.ico"
    H.body $ do
        H.article ! A.class_ "container" $ do
            H.h1 "Stanford CS240h Lab 2 Oracle"
            H.p "Questions about the spec? Ask the oracle!"
            contents

-- |HTML for a form requesting input from the user.
submitForm :: T.Text -> H.Html
submitForm t = do
    H.form ! A.action "/form" ! A.enctype "multipart/form-data" ! A.method "POST" $ do
        H.textarea ! A.name "iniFile" ! A.rows "25" ! A.cols "100"
                   ! A.style "font-family:monospace;"
                   ! A.placeholder "Your input goes here" $
                   H.toHtml t
        brClear
        H.input ! A.type_ "submit" ! A.value "Submit"

-- |Render the user's input ByteString as HTML.
showInput :: B.ByteString -> H.Html
showInput i = do
    H.h3 "Input"
    H.p "Your input was:"
    monoBlock $ show i




-- *** Handlers for GET and POST *** --

-- |After receiving user input, if a parse error occurs, this is the page we generate.
--showError :: B.ByteString -> T.Text -> String -> H.Html
--showError i t e = pageSkeleton $ do
--    showInput i
--    H.h3 ! A.style "color:red;" $ "Parse error"
--    H.p "The parser returned the following error (but note that it is probably not meaningful!):"
--    monoBlock e
--    brClear
--    submitForm t


-- |After receiving user input, if a parse is successful, this is the page we generate.
--showResult :: B.ByteString -> T.Text -> OscPattern -> H.Html
--showResult i t f = pageSkeleton $ do
--    showInput i
--    H.h3 "Parser results"
--    H.p "The parser returned the following INIFile:"
--    monoBlock $ showINIFile f
--    H.h3 "Pretty printer results"
--    H.p "The pretty printer returned the following text:"
--    monoBlock . decodeUtf8 $ prettyPrint f
--    brClear
--    submitForm t

-- TODO: use hint-server to run a _safe_ interpreter for haskell expressions in webserver.
-- interpretOscPattern  :: (MonadIO m, Control.Monad.Catch.MonadMask m) => String -> m (Either InterpreterError OscPattern)
interpretOscPattern inputString = HaskellInterpreter.runInterpreter $ do
    HaskellInterpreter.set [languageExtensions := [OverloadedStrings]]
    HaskellInterpreter.setImports ["Prelude","Sound.Tidal.Context","Sound.OSC.Type","Sound.OSC.Datum","Data.Map"]
    HaskellInterpreter.interpret inputString (HaskellInterpreter.as::OscPattern)

-- Interpret OscPattern
patternOrSilence :: Either HaskellInterpreter.InterpreterError OscPattern -> IO OscPattern
patternOrSilence (Left err) = do
  putStrLn (show err)
  return $ Tidal.sound (Tidal.p "")
patternOrSilence (Right patt) = do
  putStrLn (show patt)
  return patt

showOsc :: B.ByteString -> Either HaskellInterpreter.InterpreterError OscPattern -> H.Html
showOsc inputString (Left err) = pageSkeleton $ do
    showInput inputString
    H.h3 ! A.style "color:red;" $ "Parse error"
    H.p "The parser returned the following error:"
    monoBlock (show err)
    brClear

showOsc inputString (Right oscPattern) = pageSkeleton $ do
    showInput inputString
    H.h3 ! A.style "color:green;" $ "Interpreted Pattern"
    monoBlock (show oscPattern)
    brClear

toStrictBS :: BL.ByteString -> B.ByteString
toStrictBS = B.concat . BL.toChunks

--getSound :: String -> IO Either HaskellInterpreter.InterpreterError OscPattern
getSound inputString = do
    tidalStream <- Tidal.dirtStream
    errorOrOscPattern <- interpretOscPattern inputString
    sound <- patternOrSilence errorOrOscPattern
    _ <- tidalStream $ sound
    return errorOrOscPattern

-- |After receiving user input, attempt a parse, and then call the appropriate handler.
postResponse :: ServerPart Response
postResponse = do method POST
                  -- TODO: don't reinitialize on each request
                  inputLazyBS <- lookBS "iniFile"
                  errorOrOscPattern <- liftIO $ getSound (BL.unpack inputLazyBS)
                  ok . toResponse $ showOsc (toStrictBS inputLazyBS) errorOrOscPattern
                  --let sErr = showError inputString iniFileText
                  --let sRes = showResult inputString iniFileText
                  --ok . toResponse $ either sErr sRes iniParsed

-- |Before receiving user input, display a form requesting some input.
getResponse :: ServerPart Response
getResponse = method GET >> ( ok . toResponse . pageSkeleton $ submitForm "bd bd sn" )


-- *** Misc *** --

-- |Remove linefeed characters (@\r@) from the input stream.
--
-- We generally assume that line endings are in UNIX format, but web
-- browsers generally use Windows-ish line endings (i.e., "\r\n").
-- To mitigate this, we just strip all linefeeds out of the response.
removeLF :: T.Text -> T.Text
removeLF = T.filter $ \c -> c /= '\r'

-- |Generic configuration for the server.
parserServerConfig :: ServerConfig
parserServerConfig = ServerConfig { port = 8888
                                  , ramQuota = 65535
                                  , diskQuota = 0
                                  , tmpDir = "/dev/null"
                                  }

-- |Main - kick off the web server
main :: IO ()
main = serve (Just parserServerConfig) $ msum [getResponse, postResponse]

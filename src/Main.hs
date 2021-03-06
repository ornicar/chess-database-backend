{-# LANGUAGE OverloadedStrings, ScopedTypeVariables #-}
module Main where

import Data.Maybe
import Control.Comonad
import qualified Data.ByteString.Char8 as B
import           Data.IORef
import Snap.Snaplet.PostgresqlSimple
import           Control.Monad.State
import Control.Lens (view)
import qualified Services.Service as S
import Data.Either
import           Snap.Snaplet.Config
import           Snap.Http.Server
import           Snap.Snaplet
import System.Environment (lookupEnv)
import Control.Monad.IO.Class (liftIO)

import AppTypes
import Application 

readSettings :: IO Settings
readSettings = do
  appTypeEnv :: Maybe String <- liftIO $ lookupEnv "type"
  let appType_ = maybe Dev getAppType appTypeEnv
  return $ getSettings appType_

main :: IO ()
main = do
  settings <- readSettings
  print settings
  let config = setPort (appPort settings) defaultConfig
  serveSnaplet config $ app settings


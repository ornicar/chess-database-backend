{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE EmptyDataDecls             #-}
{-# LANGUAGE FlexibleContexts           #-}
{-# LANGUAGE GADTs                      #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE MultiParamTypeClasses      #-}
{-# LANGUAGE OverloadedStrings          #-}
{-# LANGUAGE QuasiQuotes                #-}
{-# LANGUAGE TemplateHaskell            #-}
{-# LANGUAGE TypeFamilies               #-}
{-# LANGUAGE ScopedTypeVariables        #-}

module Test.Fixtures where

import qualified Database.Persist as Ps
import qualified Database.Persist.Postgresql as PsP
import qualified Data.ByteString.Char8 as B
import           Database.Persist.TH
import           Database.Persist.Sql
import           Database.PostgreSQL.Simple.Time
import           Control.Monad.Logger (runNoLoggingT, NoLoggingT, runStderrLoggingT)
import Data.Time
import qualified Data.Text as Te
import qualified Data.List as L
import qualified Data.Maybe as M
import Data.Maybe
import Data.Either
import Control.Monad.IO.Class
import Control.Applicative
import Control.Monad.Trans.Resource
import Control.Monad.Trans.Reader (ReaderT)
import Control.Monad.Reader.Class
import Control.Monad.Reader
import qualified Data.Either.Combinators as EitherC
import Debug.Trace
import Text.RawString.QQ
import qualified Data.Attoparsec.Text as Parsec

import Services.Types
import Test.Helpers as Helpers

import qualified Chess.Pgn.Logic as Pgn
import qualified Chess.Logic as Logic

import qualified Chess.Helpers as Helpers

import qualified Chess.Board as Board
import qualified Chess.Stockfish as Stockfish

-- The connection string is obtained from the command line
-- Also, get settings for whether to create fake data.

connString :: String -> String
connString dbName = "host=localhost dbname=chess_" ++ dbName ++ " user=postgres"

-- | The settings are obtained from the command line and determine
-- how the data is stored.
-- If the `settingsDelete` flag is set, all data is deleted from the database
-- before data is read in.
-- By default, data is not overwritten. If the program is stopped in the middle of inserting data
-- then running it again should simply continue the data insertion.
--
data Settings = Settings { 
    settingsDBName :: String
  , settingsRunEval :: Bool
  , settingsOnlyContinueEval :: Bool} deriving (Show)

type IsTest = Bool
type OnlyContinue = Bool

data SettingsInput = SettingsInput IsTest OnlyContinue

doNothing :: IO ()
doNothing = do
  return ()

runJob :: Settings -> IO ()
runJob settings = do
  let conn = connString $ settingsDBName settings
  let onlyContinueEval = settingsOnlyContinueEval settings
  if not onlyContinueEval then deleteDBContents conn else doNothing
  runReaderT readerActions settings
  return ()

doNothing' = do
  return ()

readerActions = do
  continue <- reader settingsOnlyContinueEval
  evaluate <- reader settingsRunEval
  if continue 
    then do
      if evaluate then do evaluateGames else doNothing'
    else do
      storeGamesIntoDB
      if evaluate then do evaluateGames else doNothing'
  return ()

numberOfGames = 200

getDBType :: String -> IsTest
getDBType "prod" = False
getDBType _ = True

getFiles :: IsTest -> [String]
getFiles True = ["game.pgn"]
getFiles False = ["tata2.pgn"]

storeGamesIntoDB :: (MonadReader Settings m, MonadIO m) => m ()
storeGamesIntoDB = do
  dbName <- reader settingsDBName
  mapM_ storeFileIntoDB $ getFiles $ getDBType dbName

storeFileIntoDB :: (MonadReader Settings m, MonadIO m) => String -> m [Maybe (Ps.Key Game)]
storeFileIntoDB fileName = do
  dbName <- reader settingsDBName
  res <- liftIO $ inBackend (connString dbName) $ do
    dbResult <- Ps.insert (Database fileName True)
    let fullName = "./test/files/" ++ fileName
    games :: [Pgn.ParsedGame] <- liftIO $ Pgn.getGames fullName numberOfGames
    gameResults <- mapM (storeGameIntoDB dbResult) $ rights games
    return gameResults
  return res

evaluateGames :: (MonadReader Settings m, MonadIO m) => m ()
evaluateGames = do
  isTest <- fmap getDBType $ reader settingsDBName
  if isTest then evaluateGamesTest else evaluateGamesReal
  return ()

evaluateGamesReal :: (MonadReader Settings m, MonadIO m) => m ()
evaluateGamesReal = do
  dbName <- reader settingsDBName
  continueEval <- reader settingsOnlyContinueEval
  games <- liftIO $ inBackend (connString dbName) $ do
    dbGames :: [Entity Game] <- getGamesFromDB continueEval
    return dbGames
  liftIO $ print $ "Games:" ++ show (length games)
  evaluations :: [Key MoveEval] <- fmap concat $ mapM doEvaluation games
  return ()

evaluateGamesTest :: (MonadReader Settings m, MonadIO m) => m ()
evaluateGamesTest = do
  liftIO $ print "Test evaluation"
  evaluateGamesReal
  return ()

doEvaluation :: (MonadReader Settings m, MonadIO m) => Entity Game -> m [Key MoveEval]
doEvaluation dbGame = do
  let maybeGame = dbGameToPGN $ entityVal $ dbGame
  keys <- case maybeGame of 
    (Just game) -> do
      summaries <- liftIO $ Pgn.gameSummaries game
      dbName <- reader settingsDBName
      keys <- liftIO $ inBackend (connString dbName) $ do
        k <- Ps.insertMany $ evalToRow (entityKey dbGame) summaries
        return k
      return keys
    Nothing ->
      return []
  return keys

resultDBFormat :: Pgn.PgnTag -> Int
resultDBFormat (Pgn.PgnResult Pgn.WhiteWin) = 1
resultDBFormat (Pgn.PgnResult Pgn.BlackWin) = -1
resultDBFormat (Pgn.PgnResult Pgn.Draw) = 0
resultDBFormat _ = 0

getDate :: [Pgn.PgnTag] -> Maybe Day
getDate tags = join $ fmap (\(Pgn.PgnDate d) -> EitherC.rightToMaybe (Parsec.parseOnly dateStringParse (Te.pack d))) $ listToMaybe $ filter filterDate tags

dateStringParse :: Parsec.Parser Day
dateStringParse = do
  year <- Parsec.many' Parsec.digit
  Parsec.char '.'
  month <- Parsec.many' Parsec.digit
  Parsec.char '.'
  day <- Parsec.many' Parsec.digit
  return $ fromGregorian (read year :: Integer) (read month :: Int) (read day :: Int)

storeGameIntoDB :: Key Database -> Pgn.PgnGame -> DataResult (Maybe (Key Game))
storeGameIntoDB dbResult g = do
  let pgn = Pgn.gamePgnFull $ Pgn.parsedPgnGame g
  let tags = (Pgn.pgnGameTags g) :: [Pgn.PgnTag]
  let requiredTags = trace (show tags) $ parseRequiredTags tags
  if isJust requiredTags 
    then do
      let parsedTags = fromJust requiredTags
      (playerWhite, playerBlack) <- storePlayers parsedTags
      tournament <- storeTournament parsedTags
      let resultInt = resultDBFormat $ requiredResult parsedTags
      let date = getDate tags -- Maybe Day
      -- Storing the game
      let gm = (Game dbResult playerWhite playerBlack resultInt tournament pgn date)
      gameResult <- fmap keyReader $ Ps.insertBy gm
      -- Storing the tags
      let formattedTags = fmap formatForDB $ filter (not . isPlayer) tags
      mapM_ (\(name, val) -> Ps.insert (GameAttribute gameResult name val)) formattedTags
      addRatings
      return $ Just gameResult
    else do
      return Nothing

data RequiredTags = RequiredTags {
    requiredWhitePlayer :: Pgn.PgnTag
  , requiredBlackPlayer :: Pgn.PgnTag
  , requiredResult :: Pgn.PgnTag
  , requiredEvent :: Pgn.PgnTag}

parseRequiredTags :: [Pgn.PgnTag] -> Maybe RequiredTags
parseRequiredTags tags = RequiredTags <$> maybeWhite <*> maybeBlack <*> maybeResult <*> maybeEvent
  where maybeWhite = Helpers.safeHead $ filter filterWhitePlayer tags
        maybeBlack = Helpers.safeHead $ filter filterBlackPlayer tags
        maybeResult = Helpers.safeHead $ filter filterResult tags
        maybeEvent = Helpers.safeHead $ filter filterEvent tags
  
isPlayer :: Pgn.PgnTag -> Bool
isPlayer (Pgn.PgnWhite _) = True
isPlayer (Pgn.PgnBlack _) = True
isPlayer _ = False

filterWhitePlayer :: Pgn.PgnTag -> Bool
filterWhitePlayer (Pgn.PgnWhite _) = True
filterWhitePlayer _ = False

filterBlackPlayer :: Pgn.PgnTag -> Bool
filterBlackPlayer (Pgn.PgnBlack _) = True
filterBlackPlayer _ = False

filterResult :: Pgn.PgnTag -> Bool
filterResult (Pgn.PgnResult _) = True
filterResult _ = False

filterEvent :: Pgn.PgnTag -> Bool
filterEvent (Pgn.PgnEvent _) = True
filterEvent _ = False

filterDate :: Pgn.PgnTag -> Bool
filterDate (Pgn.PgnDate _) = True
filterDate _ = False

keyReader = either entityKey id

-- | Adds structured player ratings to the database.
-- These ratings are already stored in raw format as part of the 
-- `game_tag` table. Here, we turn this raw data into monthly player
-- evaluations. 
-- The monthly evaluation is simply the average of the player's raw rating
-- over all games in a certain month. If a player has not played any games in 
-- a certain month, the `player_rating` table will not contain any data for this month.
-- If you are using this data to report player ratings graphs, you might
-- want to fill in this missing time period with the latest preceding rating.

ratingQuery = [r|
SELECT player_id, extract(year from date) as year, extract(month from date) as month, avg(rating)::Int
FROM (
  SELECT player_black_id as player_id, date, value::Int as rating
  FROM game
  JOIN game_attribute ON game.id=game_attribute.game_id AND attribute='BlackPlayerElo'
  UNION ALL
  SELECT player_white_id as player_id, date, value::Int as rating
  FROM game
  JOIN game_attribute ON game.id=game_attribute.game_id AND attribute='WhitePlayerElo'
) values
GROUP BY player_id, year, month
|]

type RatingQueryType = (Single Int, Single Int, Single Int, Single Int)

intToKey :: Int -> Key Player
intToKey = toSqlKey . fromIntegral

readRatingQuery :: RatingQueryType -> PlayerRating
readRatingQuery (Single player_id, Single year, Single month, Single rating) = PlayerRating (intToKey player_id) year month rating

addRatings :: DataResult ()
addRatings = do
  results :: [RatingQueryType] <- rawSql ratingQuery []
  mapM_ (Ps.insertBy . readRatingQuery) results
  return ()
 

storePlayers :: RequiredTags -> DataResult (Key Player, Key Player)
storePlayers tags = do
  let (whitePlayer, blackPlayer) = (requiredWhitePlayer tags, requiredBlackPlayer tags)
  let (Pgn.PgnWhite (Pgn.Player firstWhite lastWhite)) = whitePlayer
  let (Pgn.PgnBlack (Pgn.Player firstBlack lastBlack)) = blackPlayer
  whiteResult <- Ps.insertBy (Player firstWhite lastWhite)
  blackResult <- Ps.insertBy (Player firstBlack lastBlack)
  return (keyReader whiteResult, keyReader blackResult)

storeTournament :: RequiredTags -> DataResult (Key Tournament)
storeTournament tags = do
  let (Pgn.PgnEvent eventName) = requiredEvent tags
  result <- Ps.insertBy $ Tournament eventName
  return $ keyReader result


-- select where the game id cannot be found in move_eval

sqlGamesAll = [r|
SELECT ??
FROM game
|]

sqlGamesUnevaluated = [r|
SELECT ?? 
FROM game
WHERE game.id not in (SELECT DISTINCT game_id from move_eval)
|]


getGamesFromDB :: Bool -> DataResult [Entity Game]
getGamesFromDB continueEval = do
  let query = if continueEval then sqlGamesUnevaluated else sqlGamesAll
  games :: [Entity Game] <- rawSql query []
  games <- Ps.selectList [] [LimitTo numberOfGames]
  return games

evalToRow :: Key Game -> [Pgn.MoveSummary] -> [MoveEval]
evalToRow g ms = evalToRowColor g 1 Board.White ms

evalToRowColor :: Key Game -> Int -> Board.Color -> [Pgn.MoveSummary] -> [MoveEval]
evalToRowColor _ _ _ [] = []
evalToRowColor g n (Board.White) (ms : rest) = constructEvalMove g n True ms : evalToRowColor g n (Board.Black) rest
evalToRowColor g n (Board.Black) (ms : rest) = constructEvalMove g n False ms : evalToRowColor g (n + 1) (Board.White) rest

constructEvalMove :: Key Game -> Int -> Bool -> Pgn.MoveSummary -> MoveEval
constructEvalMove gm n isWhite (Pgn.MoveSummary mv mvBest evalMove evalBest _) = MoveEval gm n isWhite mvString mvBestString (evalInt evalMove) (evalMate evalMove)
  where mvString = Just $ Board.showMove mv
        mvBestString = Board.showMove mvBest

evalInt :: Stockfish.Evaluation -> Maybe Int 
evalInt (Right n) = Just n
evalInt (Left _) = Nothing

evalMate :: Stockfish.Evaluation -> Maybe Int 
evalMate (Right _) = Nothing
evalMate (Left n) = Just n

  
dbGameToPGN :: Game -> Maybe Pgn.Game
dbGameToPGN game = EitherC.rightToMaybe $ Logic.gameFromStart Pgn.pgnToMove $ Pgn.unsafeMoves $ Te.pack $ gamePgn game



  

-- Questions I can ask
-- What was the average evaluation of Magnus' games by move number (moves 10, 20, 30)
-- compared to Giri
-- restrict to games between 2015 and 2017 and opponents >= 2700

-- averageEvalByMoveNumber :: Player -> TimeRange -> [(Int, Int)]
  
-- Controlling for own rating and opponent rating, what's the win and draw percentage
-- based on the computer evaluation?
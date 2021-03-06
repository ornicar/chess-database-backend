-- |This contains all raw SQL pulls and related functions. I pull these out
-- into their own module. The next step is to cleanly encapsulate them and only
-- expose safe functions that cannot cause runtime errors.

{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE DeriveGeneric     #-}
{-# LANGUAGE DeriveAnyClass     #-}


module Services.Sql where

import qualified Data.Text as T (Text, pack, unpack)
import qualified Data.Text.Lazy as TL (toStrict)
import Text.RawString.QQ (r)
import Data.Text.Template (Context, substitute)
import Services.DatabaseHelpers (listToInClause)
import Data.Maybe (fromMaybe)


type GameList = [Int]

substituteGameList :: T.Text -> GameList -> T.Text
substituteGameList template ints = TL.toStrict $ substitute template cont
  where cont = context [("gameList", listToInClause ints)]

-- | Create 'Context' from association list.
context :: [(String, String)] -> Context
context assocs x = T.pack $ fromMaybe err . lookup (T.unpack x) $ assocs
  where err = error $ "Could not find key: " ++ T.unpack x

-- |Summarizes a `Database` through the following metrics:
-- number of tournaments
-- number of games
-- number of games with evaluations
-- number of evaluated moves
dataSummaryQuery :: T.Text
dataSummaryQuery = [r|
WITH 
    numberTournaments as (SELECT count(distinct id) as "numberTournaments" FROM tournament where database_id=?)
  , numberGames as (SELECT count(distinct id) as "numberGames" FROM game where database_id=?)
  , numberGameEvals as (
      SELECT count(distinct id) as "numberGameEvals" FROM (
          SELECT id FROM game WHERE id in (
            SELECT DISTINCT game_id FROM move_eval
          ) and game.database_id=?
      ) as numberGameEvals
    )
  , numberMoveEvals as (
      SELECT count(*) as "numberMoveEvals" 
      FROM move_eval
      JOIN game on move_eval.game_id = game.id
      WHERE game.database_id=?
    )
SELECT * 
FROM numberTournaments
CROSS JOIN numberGames
CROSS JOIN numberGameEvals
CROSS JOIN numberMoveEvals
|]


-- |Creates a view that calculates the centipawn loss of a move. This is done
-- taking the difference between the evaluation after the move that was best and
-- the move that was made. Doing this quickly requires using a lag function in postgres
-- thus, this is done in SQL, not through Esqueleto.
-- In pseudo-code, the evaluation of a move is max(eval - lag(eval, 1), 0) if the player that moves 
-- had the white pieces and the inverse of that if the player was playing with the  black pieces.
viewQuery :: T.Text
viewQuery = [r|
CREATE OR REPLACE VIEW moveevals as (
  SELECT 
    game_id
  , is_white
  , move_number
  , greatest(((is_white :: Int)*2-1)*(eval_best - eval), 0) as cploss
  FROM move_eval
);
|]

evalQueryTemplate :: T.Text
evalQueryTemplate = [r|
  WITH me_player as (
    SELECT g.id as game_id, player_white_id, player_black_id, is_white, cploss, game_result
    FROM moveevals me
    JOIN game g
    ON me.game_id = g.id
    WHERE g.id in $gameList
  )
  SELECT game_id, player_white_id as player_id, avg(cploss)::Int as cploss, avg((game_result+1)*100/2)::Int as result from me_player WHERE is_white group by game_id, player_white_id
  UNION ALL
  SELECT game_id, player_black_id as player_id, avg(cploss)::Int as cploss, avg((-game_result+1)*100/2)::Int as result from me_player WHERE not is_white group by game_id, player_black_id;
|]

resultPercentageQuery :: T.Text
resultPercentageQuery = [r|
SELECT rating_own
    , rating_opponent
    , (100 * avg((result=1)::Int))::Int as share_win
    , (100 * avg((result=0)::Int)) :: Int as share_draw
FROM (
  SELECT game_result as result
      , 100 * floor(rating1.rating/100) as rating_own
      , 100 * floor(rating2.rating/100) as rating_opponent
      , eval, move_number
  FROM game
  JOIN player_rating as rating1 ON 
        game.player_white_id=rating1.player_id
    AND extract(year from game.date)=rating1.year
    AND extract(month from game.date)=rating1.month
  JOIN player_rating as rating2 ON 
        game.player_black_id=rating2.player_id
    AND extract(year from game.date)=rating2.year
    AND extract(month from game.date)=rating2.month
  JOIN move_eval on game.id=move_eval.game_id
  WHERE is_white AND move_number>0 and game.database_id=?
) values
GROUP BY rating_own, rating_opponent
|]


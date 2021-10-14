{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE TypeApplications #-}

module Main where

import Control.Monad.State
-- import Data.Text
-- import Data.Text.IO(putStrLn)
-- import Prelude hiding(putStrLn)
import TextShow
import TextShow.TH
import Surface
import System.Console.ANSI

data Path a where
  PTop          :: Path a
  PLamParamList :: Path Term -> [String] -> [String] -> Term -> Path String
  PLamBody      :: Path Term -> [String] -> Path Term
  PLamAddParam  :: Path Term -> [String] -> Term -> Path String
  PApp          :: Path Term -> [Term] -> [Term] -> Path Term
deriving instance Show (Path a)

data PathType a where
  PTerm :: PathType Term
  PName :: PathType String

data Focus a where
  FName :: String -> Focus String
  FTerm :: Term -> Focus Term
deriving instance Show (Focus a)

unFName :: Focus String -> String
unFName (FName s) = s

unFTerm :: Focus Term -> Term
unFTerm (FTerm e) = e

data FocusType a where
  FTName :: FocusType String
  FTTerm   :: FocusType Term

data Cursor a = Cursor { unFocus :: Focus a, unPath :: Path a }
deriving instance Show (Cursor a)

data EditorState a = EditorState { unCursor :: Cursor a, unFocusType :: FocusType a }

data Ex = forall a. Ex { unEx :: EditorState a }

data Command a where
  InsertLam :: String -> Command Term
  InsertApp :: Command Term
  InsertVar :: String -> Command Term
  SetName   :: String -> Command String
  MoveOut   :: Command a
  MoveRight :: Command a
  MoveLeft  :: Command a
  MoveIn    :: Command a
  Add       :: Command a

run :: Command a -> EditorState a -> Ex
run command state@(EditorState (Cursor focus path) _) = case command of
  InsertLam n -> Ex $ EditorState (Cursor (FName "") (PLamAddParam path [n] Hole)) FTName
  InsertVar s -> Ex $ EditorState (Cursor (FTerm $ Var (Name s)) path) FTTerm
  SetName s -> Ex $ EditorState (Cursor (FName s) path) FTName
  MoveRight -> case path of
    PTop -> Ex state
    PLamParamList up ln [] body -> Ex $ EditorState (Cursor (FName "") (PLamAddParam up (ln ++ [unFName focus]) body)) FTName
    PLamParamList up ln rs body -> Ex $ EditorState (Cursor (FName $ last rs) (PLamParamList up (ln ++ [unFName focus]) (init rs) body)) FTName
    PLamAddParam up ns body ->
      if unFName focus == "" then
        Ex $ EditorState (Cursor (FTerm body) (PLamBody up ns)) FTTerm
      else
        Ex $ EditorState (Cursor (FName "") (PLamAddParam up (ns ++ [unFName focus]) body)) FTName
  MoveLeft -> case path of
    PTop -> Ex state
    PLamParamList up (l:ln) rn body -> Ex $ EditorState (Cursor (FName l) (PLamParamList up ln ((unFName focus):rn) body)) FTName
    PLamParamList up [] rn body -> run MoveOut state
    PLamAddParam up ns body -> Ex $ EditorState (Cursor (FName (last ns)) (PLamParamList up (init ns) [] body)) FTName
    PLamBody up ns -> Ex $ EditorState (Cursor (FName "") (PLamAddParam up ns (unFTerm focus))) FTName
  MoveOut -> case path of
    PTop -> Ex state
    PLamParamList up ln rn body -> Ex $ EditorState (Cursor (FTerm (Lam (map Name ln ++ map Name rn) body)) up) FTTerm
    PLamBody up ns -> Ex $ EditorState (Cursor (FTerm $ Lam (map Name ns) (unFTerm focus)) up) FTTerm
    PLamAddParam up ns body -> Ex $ EditorState (Cursor (FTerm $ Lam (map Name ns) body) up) FTTerm
  MoveIn -> case focus of
    FTerm focus -> case focus of
      Lam ns body -> Ex $ EditorState (Cursor (FTerm body) (PLamBody path (map unName ns))) FTTerm
    FName _ -> Ex state

render :: EditorState a -> String
render (EditorState (Cursor focus path) _) = renderPath ("[" ++ renderFocus focus ++ "]") path where
  renderFocus :: Focus a -> String
  renderFocus focus = case focus of
    FName s -> s
    FTerm term -> renderTerm term
  renderTerm :: Term -> String
  renderTerm term = case term of
    Lam names body -> "fun " ++ snames (map unName names) ++ "-> " ++ renderTerm body
    Var (Name s) -> s
    Hole -> "?"
  renderPath :: String -> Path a -> String
  renderPath focus path = case path of
    PTop -> focus
    PLamBody up names -> renderPath ("fun " ++ snames names ++ "-> " ++ focus) up where
    PLamParamList up ln rn body -> renderPath ("fun " ++ snames ln ++ focus ++ snames rn ++ "-> " ++ renderTerm body) up
    PLamAddParam up ns body -> renderPath ("fun " ++ snames ns ++ focus ++ "-> " ++ renderTerm body) up
  snames ns = case ns of
    [] -> ""
    n:ns -> n ++ " " ++ snames ns

loop :: EditorState a -> IO ()
loop state = do
  clearScreen
  putStrLn (render state)
  s <- getLine
  state <- case (s, unFocusType state) of
    ("r", _) -> pure $ run MoveRight state
    ("l", _) -> pure $ run MoveLeft state
    ("o", _) -> pure $ run MoveOut state
    ("i", _) -> pure $ run MoveIn state
    ("lam", FTTerm) -> do
      n <- getLine
      pure $ run (InsertLam n) state
    (_, FTTerm) -> pure $ run (InsertVar s) state
    (_, FTName) -> pure $ run (SetName s) state
  next state
  where
    next :: Ex -> IO ()
    next (Ex state) = loop state

main :: IO ()
main = loop (EditorState (Cursor (FTerm Hole) PTop) FTTerm)
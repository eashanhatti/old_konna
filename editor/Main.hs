{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE ForeignFunctionInterface #-}
{-# LANGUAGE OverloadedStrings #-}

module Main where

-- import Data.Text
-- import Data.Text.IO(putStrLn)
-- import Prelude hiding(putStrLn)
import TextShow
import TextShow.TH
import Surface
import System.Console.ANSI
import Data.Binary
import Data.Binary.Put
import Data.Binary.Get(runGet)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import qualified Data.ByteString.Lazy as LB
import Data.List(intersperse)
import Prelude hiding (Left, Right)
import Parsing(getItem)
import System.IO
import GHC.IO.Encoding
import Data.Char
import Foreign.C.Types

data Con = Con String Term | EditorBlankCon
  deriving (Show, Eq)

data Path a where
  PTop                 :: Path Item
  PTermDefName         :: Path Item -> Term -> Term -> Path String
  PTermDefBody         :: Path Item -> String -> Term -> Path Term
  PTermDefTy           :: Path Item -> String -> Term -> Path Term
  PNamespaceDefName    :: Path Item -> [Item] -> Path String
  PNamespaceDefItems   :: Path Item -> String -> [Item] -> [Item] -> Path Item
  PNamespaceDefAddItem :: Path Item -> String -> [Item] -> [Item] -> Path Item
  PIndDefName          :: Path Item -> Term -> [Con] -> Path String
  PIndDefTy            :: Path Item -> String -> [Con] -> Path Term
  PIndDefCons          :: Path Item -> String -> Term -> [Con] -> [Con] -> Path Con
  PIndDefAddCon        :: Path Item -> String -> Term -> [Con] -> [Con] -> Path Con
  PConName             :: Path Con  -> Term -> Path String
  PConTy               :: Path Con  -> String -> Path Term
  PLamParams           :: Path Term -> [String] -> [String] -> Term -> Path String
  PLamAddParam         :: Path Term -> [String] -> [String] -> Term -> Path String
  PLamBody             :: Path Term -> [String] -> Path Term
  PAppTerms            :: Path Term -> [Term] -> [Term] -> Path Term
  PAppAddTerm          :: Path Term -> [Term] -> [Term] -> Path Term
  PLetName             :: Path Term -> Term -> Term -> Term -> Path String
  PLetDefTy            :: Path Term -> String -> Term -> Term -> Path Term
  PLetDef              :: Path Term -> String -> Term -> Term -> Path Term
  PLetBody             :: Path Term -> String -> Term -> Term -> Path Term
  PPiName              :: Path Term -> Term -> Term -> Path String
  PPiIn                :: Path Term -> String -> Term -> Path Term
  PPiOut               :: Path Term -> String -> Term -> Path Term
  PCode                :: Path Term -> Path Term
  PQuote               :: Path Term -> Path Term
  PSplice              :: Path Term -> Path Term
deriving instance Show (Path a)
deriving instance Eq (Path a)

data Focus a where
  FName :: String -> Focus String
  FTerm :: Term -> Focus Term
  FItem :: Item -> Focus Item
  FCon  :: Con -> Focus Con
deriving instance Show (Focus a)
deriving instance Eq (Focus a)

unFName :: Focus String -> String
unFName (FName s) = s
unFTerm :: Focus Term -> Term
unFTerm (FTerm e) = e
unFItem :: Focus Item -> Item
unFItem (FItem i) = i
unFCon :: Focus Con -> Con
unFCon  (FCon c)  = c

data FocusType a where
  FTName :: FocusType String
  FTTerm :: FocusType Term
  FTItem :: FocusType Item
  FTCon  :: FocusType Con
deriving instance Eq (FocusType a)
deriving instance Show (FocusType a)

data Cursor a = Cursor { unFocus :: Focus a, unPath :: Path a }
deriving instance Show (Cursor a)
deriving instance Eq (Cursor a)

data EditorState a = EditorState { unCursor :: Cursor a, unFocusType :: FocusType a, unSide :: Direction }
deriving instance Eq (EditorState String)
deriving instance Eq (EditorState Term)
deriving instance Eq (EditorState Item)
deriving instance Eq (EditorState Con)
deriving instance Show (EditorState a)

statesEq :: EditorState a -> EditorState b -> Bool
statesEq st st' = case (unFocusType st, unFocusType st') of
  (FTName, FTName) -> st == st'
  (FTTerm, FTTerm) -> st == st'
  (FTItem, FTItem) -> st == st'
  (FTCon, FTCon) -> st == st'
  _ -> False

data Ex = forall a. Ex { unEx :: EditorState a }

data Command a where
  InsertTerm         :: TermInsertionType -> Command Term
  InsertVar          :: String -> Command Term
  InsertHole         :: Command Term
  InsertU0           :: Command Term
  InsertU1           :: Command Term
  InsertTermDef      :: Command Item
  InsertNamespaceDef :: Command Item
  InsertIndDef       :: Command Item
  InsertGVar         :: [String] -> Command Term
  InsertCon          :: Command Con
  SetName            :: String -> Command String
  MoveOut            :: Direction -> Command a
  MoveRight          :: Command a
  MoveLeft           :: Command a
  MoveInLeft         :: Command a
  MoveInRight        :: Command a
  Add                :: Command a

data Direction = Left | Right
  deriving (Eq, Show)

class MkFT a where focusType :: FocusType a
instance MkFT Term where   focusType = FTTerm
instance MkFT String where focusType = FTName
instance MkFT Item where   focusType = FTItem
instance MkFT Con where    focusType = FTCon

class MkFocus a where focus :: a -> Focus a
instance MkFocus Term where   focus = FTerm
instance MkFocus Item where   focus = FItem
instance MkFocus String where focus = FName
instance MkFocus Con where    focus = FCon

mkEx :: (MkFT a, MkFocus a) => a -> Path a -> Direction -> Ex
mkEx f p s = Ex $ EditorState (Cursor (focus f) p) focusType s

blankFocus :: Focus a -> Bool
blankFocus focus = case focus of
  FTerm EditorBlank -> True
  FItem EditorBlankDef -> True
  FName "" -> True
  FCon EditorBlankCon -> True
  _ -> False

run :: Command a -> EditorState a -> Ex
run command state@(EditorState (Cursor focus path) _ side) = case command of
  InsertTerm ti -> case ti of
    TILam -> mkEx (Lam [Name "_"] termFocus) path Left
    TIApp -> mkEx (App termFocus [Hole]) path Left
    TILet -> mkEx (Let (Name "_") Hole Hole termFocus) path Left
    TIPi -> mkEx (Pi (Name "_") termFocus Hole) path Left
    TICode -> mkEx (Code termFocus) path Left
    TIQuote -> mkEx (Quote termFocus) path Left
    TISplice -> mkEx (Splice termFocus) path Left
    where
      termFocus = unFTerm focus
  -- InsertLam -> mkEx (Lam [Name "_"] Hole) path Left
  -- InsertApp -> mkEx (App Hole [Hole]) path Left
  InsertVar s -> mkEx (Var (Name s)) path Left
  InsertHole -> mkEx Hole path Left
  -- InsertLet -> mkEx (Let (Name "_") Hole Hole Hole) path Left
  InsertTermDef -> mkEx (TermDef (Name "_") Hole Hole) path Left
  InsertNamespaceDef -> mkEx (NamespaceDef (Name "_") []) path Left
  InsertIndDef -> mkEx (IndDef (Name "_") Hole []) path Left
  -- InsertPi -> mkEx (Pi (Name "_") Hole Hole) path Left
  InsertU0 -> mkEx U0 path Left
  InsertU1 -> mkEx U1 path Left
  -- InsertCode -> mkEx (Code Hole) path Left
  -- InsertQuote -> mkEx (Quote Hole) path Left
  -- InsertSplice -> mkEx (Splice Hole) path Left
  InsertGVar ns -> mkEx (GVar $ GName ns) path Left
  InsertCon -> mkEx (Con "_" Hole) path Left
  SetName s -> mkEx s path Left
  Add ->
    if blankFocus focus then
      Ex state
    else case path of
      PLamParams up ln rn body -> goLam up ln rn body focus
      PLamAddParam up ln rn body -> goLam up ln rn body focus
      PAppTerms up le re -> goApp up le re focus
      PAppAddTerm up le re -> goApp up le re focus
      PNamespaceDefItems up name li ri -> goNamespace up name li ri focus
      PNamespaceDefAddItem up name li ri -> goNamespace up name li ri focus
      PIndDefCons up name ty lc rc -> goInd up name ty lc rc focus
      PIndDefAddCon up name ty lc rc -> goInd up name ty lc rc focus
      _ -> Ex state
      where
        goInd up name ty lc rc focus = mkEx EditorBlankCon (PIndDefAddCon up name ty (lc ++ [unFCon focus]) rc) Left
        goNamespace up name li ri focus = mkEx EditorBlankDef (PNamespaceDefAddItem up name (li ++ [unFItem focus]) ri) Left
        goApp up le re focus = mkEx EditorBlank (PAppAddTerm up (le ++ [unFTerm focus]) re) Left
        goLam up ln rn body focus = mkEx "" (PLamAddParam up (ln ++ [unFName focus]) rn body) Left
  MoveRight -> case path of
    PTop -> sideRight
    PLamParams up ln [] body -> mkEx body (PLamBody up (ln ++ [unFName focus])) Left
    PLamParams up ln (n:rn) body -> mkEx n (PLamParams up (ln ++ [unFName focus]) rn body) Left
    PLamAddParam up ln rn body -> case (rn, unFName focus) of
      ([], "") -> mkEx body (PLamBody up ln) Left
      (n:rn, "") -> mkEx n (PLamParams up ln rn body) Left
      ([], fn) -> mkEx "" (PLamAddParam up (ln ++ [fn]) [] body) Left
      (_:_, fn) -> mkEx "" (PLamAddParam up (ln ++ [fn]) rn body) Left
    PLamBody up ns -> sideRight
    PAppAddTerm up le re -> case (re, unFTerm focus) of
      ([], EditorBlank) -> sideRight
      (e:re, EditorBlank) -> mkEx e (PAppTerms up le re) Left
      ([], fe) -> sideRight
      (e:re, fe) -> mkEx e (PAppTerms up (le ++ [fe]) re) Left
    PAppTerms up le [] -> sideRight
    PAppTerms up le (r:re) -> mkEx r (PAppTerms up (le ++ [unFTerm focus]) re) Left
    PLetName up def defTy body -> mkEx defTy (PLetDefTy up (unFName focus) def body) Left
    PLetDefTy up name def body -> mkEx def (PLetDef up name (unFTerm focus) body) Left
    PLetDef up name defTy body -> mkEx body (PLetBody up name (unFTerm focus) defTy) Left
    PLetBody _ _ _ _ -> sideRight
    PTermDefName up ty body -> mkEx ty (PTermDefTy up (unFName focus) body) Left
    PTermDefTy up name body -> mkEx body (PTermDefBody up name (unFTerm focus)) Left
    PTermDefBody _ _ _ -> sideRight
    PNamespaceDefName up [] -> mkEx EditorBlankDef (PNamespaceDefAddItem up (unFName focus) [] []) Left
    PNamespaceDefName up (i:is) -> mkEx i (PNamespaceDefItems up (unFName focus) [] is) Left
    PNamespaceDefItems up name _ [] -> sideRight
    PNamespaceDefItems up name li (i:ri) -> mkEx i (PNamespaceDefItems up name (li ++ [unFItem focus]) ri) Left
    PNamespaceDefAddItem up name li ri -> case (ri, unFItem focus) of
      ([], EditorBlankDef) -> sideRight
      (i:ri, EditorBlankDef) -> mkEx i (PNamespaceDefItems up name li ri) Left
      ([], fi) -> sideRight
      (i:ri, fi) -> mkEx i (PNamespaceDefItems up name (li ++ [fi]) ri) Left
    PPiName up inTy outTy -> mkEx inTy (PPiIn up (unFName focus) outTy) Left
    PPiIn up name outTy -> mkEx outTy (PPiOut up name (unFTerm focus)) Left
    PPiOut _ _ _ -> sideRight
    PCode _ -> sideRight
    PQuote _ -> sideRight
    PSplice _ -> sideRight
    PIndDefName up ty cons -> mkEx ty (PIndDefTy up (unFName focus) cons) Left
    PIndDefTy up name [] -> mkEx EditorBlankCon (PIndDefAddCon up name (unFTerm focus) [] []) Left 
    PIndDefTy up name (c:cs) -> mkEx c (PIndDefCons up name (unFTerm focus) [] cs) Left
    PIndDefCons up name ty lc [] -> sideRight
    PIndDefCons up name ty lc (c:rc) -> mkEx c (PIndDefCons up name ty (lc ++ [unFCon focus]) rc) Left
    PIndDefAddCon up name ty lc rc -> case (rc, unFCon focus) of
      ([], EditorBlankCon) -> sideRight
      (c:rc, EditorBlankCon) -> mkEx c (PIndDefCons up name ty lc rc) Left
      ([], fc) -> sideRight
      (c:rc, fc) -> mkEx c (PIndDefCons up name ty (lc ++ [fc]) rc) Left
    PConName up ty -> mkEx ty (PConTy up (unFName focus)) Left
    PConTy _ _ -> sideRight
  MoveLeft -> case path of
    PTop -> sideLeft
    PLamParams up [] rn body -> mkEx "" (PLamAddParam up [] (unFName focus : rn) body) Left
    PLamParams up ln rn body -> mkEx (last ln) (PLamParams up (init ln) (unFName focus : rn) body) Left
    PLamAddParam up ln rn body -> case (length ln, unFName focus) of
      (0, "") -> sideLeft
      (_, "") -> mkEx (last ln) (PLamParams up (init ln) rn body) Left
      (0, fn) -> mkEx "" (PLamAddParam up [] (fn:rn) body) Left
      (_, fn) -> mkEx (last ln) (PLamParams up (init ln) (fn:rn) body) Left
    PLamBody up ns -> mkEx (last ns) (PLamParams up (init ns) [] (unFTerm focus)) Left
    PAppTerms up [] re -> mkEx EditorBlank (PAppAddTerm up [] (unFTerm focus : re)) Right
    PAppTerms up le re -> mkEx (last le) (PAppTerms up (init le) (unFTerm focus : re)) Right
    PAppAddTerm up le re -> case (length le, unFTerm focus) of
      (0, EditorBlank) -> sideLeft
      (_, EditorBlank) -> mkEx (last le) (PAppTerms up (init le) re) Right
      (0, fn) -> mkEx EditorBlank (PAppAddTerm up [] (fn:re)) Right
      (_, fn) -> mkEx (last le) (PAppTerms up (init le) (fn:re)) Right
    PLetName _ _ _ _ -> sideLeft
    PLetDefTy up name def body -> mkEx name (PLetName up def (unFTerm focus) body) Left
    PLetDef up name defTy body -> mkEx defTy (PLetDefTy up name (unFTerm focus) body) Right
    PLetBody up name def defTy -> mkEx def (PLetDef up name defTy (unFTerm focus)) Right
    PTermDefName up ty body -> sideLeft
    PTermDefTy up name body -> mkEx name (PTermDefName up (unFTerm focus) body) Left
    PTermDefBody up name ty -> mkEx ty (PTermDefTy up name (unFTerm focus)) Right
    PNamespaceDefName up _ -> sideLeft
    PNamespaceDefItems up name [] ri -> mkEx EditorBlankDef (PNamespaceDefAddItem up name [] (unFItem focus : ri)) Right
    PNamespaceDefItems up name li ri -> mkEx (last li) (PNamespaceDefItems up name (init li) (unFItem focus : ri)) Right
    PNamespaceDefAddItem up name li ri -> case (length li, unFItem focus) of
      (0, EditorBlankDef) -> mkEx name (PNamespaceDefName up ri) Left
      (_, EditorBlankDef) -> mkEx (last li) (PNamespaceDefItems up name (init li) ri) Right
      (0, fi) -> mkEx EditorBlankDef (PNamespaceDefAddItem up name [] (fi:ri)) Right
      (_, fi) -> mkEx (last li) (PNamespaceDefItems up name (init li) (fi:ri)) Right
    PPiName _ _ _ -> sideLeft
    PPiIn up name outTy -> mkEx name (PPiName up (unFTerm focus) outTy) Left
    PPiOut up name inTy -> mkEx inTy (PPiIn up name (unFTerm focus)) Right
    PCode _ -> sideLeft
    PQuote _ -> sideLeft
    PSplice _ -> sideLeft
    PIndDefName _ _ _ -> sideLeft
    PIndDefTy up name cons -> mkEx name (PIndDefName up (unFTerm focus) cons) Left
    PIndDefCons up name ty [] rc -> mkEx EditorBlankCon (PIndDefAddCon up name ty [] (unFCon focus : rc)) Right
    PIndDefCons up name ty lc rc -> mkEx (last lc) (PIndDefCons up name ty (init lc) (unFCon focus : rc)) Right
    PIndDefAddCon up name ty lc rc -> case (length lc, unFCon focus) of
      (0, EditorBlankCon) -> mkEx ty (PIndDefTy up name rc) Right
      (_, EditorBlankCon) -> mkEx (last lc) (PIndDefCons up name ty (init lc) rc) Right
      (0, fc) -> mkEx ty (PIndDefTy up name (fc:rc)) Right
      (_, fc) -> mkEx (last lc) (PIndDefCons up name ty (init lc) (fc:rc)) Right
    PConName _ _ -> sideLeft
    PConTy up name -> mkEx name (PConName up (unFTerm focus)) Left
  MoveOut d -> case path of
    PTop -> Ex state
    PLamParams up ln rn body -> mkEx (Lam (map Name ln ++ [Name $ unFName focus] ++ map Name rn) body) up d
    PLamBody up ns -> mkEx (Lam (map Name ns) (unFTerm focus)) up d
    PLamAddParam up ln rn body ->
      if unFName focus == "" then
        go $ map Name rn
      else
        go $ (Name $ unFName focus) : map Name rn
      where
        go rn = mkEx (Lam (map Name ln ++ rn) body) up d
    PAppTerms up le re ->
      let es = le ++ [unFTerm focus] ++ re
      in mkEx (App (head es) (tail es)) up d
    PAppAddTerm up le re ->
      let es = if unFTerm focus == EditorBlank then le ++ re else le ++ [unFTerm focus] ++ re
      in mkEx (App (head es) (tail es)) up d
    PLetName up def defTy body -> mkEx (Let (Name $ unFName focus) def defTy body) up d
    PLetDefTy up name def body -> mkEx (Let (Name name) def (unFTerm focus) body) up d
    PLetDef up name defTy body -> mkEx (Let (Name name) (unFTerm focus) defTy body) up d
    PLetBody up name def defTy -> mkEx (Let (Name name) def defTy (unFTerm focus)) up d
    PTermDefName up ty body -> mkEx (TermDef (Name $ unFName focus) ty body) up d
    PTermDefTy up name body -> mkEx (TermDef (Name name) (unFTerm focus) body) up d
    PTermDefBody up name ty -> mkEx (TermDef (Name name) ty (unFTerm focus)) up d
    PNamespaceDefName up items -> mkEx (NamespaceDef (Name $ unFName focus) items) up d
    PNamespaceDefItems up name li ri -> mkEx (NamespaceDef (Name name) (li ++ unFItem focus : ri)) up d
    PNamespaceDefAddItem up name li ri ->
      let is = if unFItem focus == EditorBlankDef then li ++ ri else li ++ [unFItem focus] ++ ri
      in mkEx (NamespaceDef (Name name) is) up d
    PPiName up inTy outTy -> mkEx (Pi (Name $ unFName focus) inTy outTy) up d
    PPiIn up name outTy -> mkEx (Pi (Name name) (unFTerm focus) outTy) up d
    PPiOut up name inTy -> mkEx (Pi (Name name) inTy (unFTerm focus)) up d
    PCode up -> mkEx (Code $ unFTerm focus) up d
    PQuote up -> mkEx (Quote $ unFTerm focus) up d
    PSplice up -> mkEx (Splice $ unFTerm focus) up d
    PIndDefName up ty cons -> mkEx (IndDef (Name $ unFName focus) ty (map (\(Con n t) -> (Name n, t)) cons)) up d
    PIndDefCons up name ty lc [] ->
      let (Con n t) = unFCon focus
      in mkEx (IndDef (Name name) ty (map (\(Con n t) -> (Name n, t)) lc ++ [(Name n, t)])) up d
    PIndDefTy up name cons -> mkEx (IndDef (Name name) (unFTerm focus) (map (\(Con n t) -> (Name n, t)) cons)) up d
    PIndDefCons up name ty lc rc ->
      let (Con n t) = unFCon focus
      in mkEx (IndDef (Name name) ty (map (\(Con n t) -> (Name n, t)) lc ++ (Name n, t) : map (\(Con n t) -> (Name n, t)) rc)) up d
    PIndDefAddCon up name ty lc rc ->
      let
        clc = map (\(Con n t) -> (Name n, t)) lc
        crc = map (\(Con n t) -> (Name n, t)) rc
        cs =
          case unFCon focus of
            EditorBlankCon -> clc ++ crc
            Con n t -> clc ++ (Name n, t):crc
      in mkEx (IndDef (Name name) ty cs) up d
    PConName up ty -> mkEx (Con (unFName focus) ty) up d
    PConTy up name -> mkEx (Con name (unFTerm focus)) up d
  MoveInLeft -> case focus of
    FTerm focus -> case focus of
      Lam (Name n:ns) body -> mkEx n (PLamParams path [] (map unName ns) body) Left
      App lam args -> mkEx lam (PAppTerms path [] args) Left
      Let (Name name) def defTy body -> mkEx name (PLetName path def defTy body) Left
      Pi (Name name) inTy outTy -> mkEx name (PPiName path inTy outTy) Left
      Var _ -> Ex state
      GVar _ -> Ex state
      U0 -> Ex state
      U1 -> Ex state
      Code ty -> mkEx ty (PCode path) Left
      Quote e -> mkEx e (PQuote path) Left
      Splice e -> mkEx e (PSplice path) Left
      Hole -> Ex state
      EditorBlank -> Ex state
    FItem focus -> case focus of
      TermDef (Name n) ty body -> mkEx n (PTermDefName path ty body) Left
      NamespaceDef (Name n) items -> mkEx n (PNamespaceDefName path items) Left
      IndDef (Name n) ty cons -> mkEx n (PIndDefName path ty (map (\(Name n, t) -> Con n t) cons)) Left
    FCon focus -> case focus of
      Con n t -> mkEx n (PConName path t) Left
      EditorBlankCon -> sideLeft
    FName _ -> sideLeft
  MoveInRight -> case focus of
    FTerm focus -> case focus of
      Lam ns body -> mkEx body (PLamBody path (map unName ns)) Right
      App lam args -> mkEx (last args) (PAppTerms path (lam : init args) []) Right
      Let (Name name) def defTy body -> mkEx body (PLetBody path name def defTy) Right
      Pi (Name name) inTy outTy -> mkEx outTy (PPiOut path name inTy) Right
      Var _ -> Ex state
      GVar _ -> Ex state
      U0 -> Ex state
      U1 -> Ex state
      Code ty -> mkEx ty (PCode path) Right
      Quote e -> mkEx e (PQuote path) Right
      Splice e -> mkEx e (PSplice path) Right
      Hole -> Ex state
      EditorBlank -> Ex state
    FItem focus -> case focus of
      TermDef (Name n) ty body -> mkEx body (PTermDefBody path n ty) Right
      NamespaceDef (Name n) [] -> mkEx EditorBlankDef (PNamespaceDefItems path n [] []) Right
      NamespaceDef (Name n) items -> mkEx (last items) (PNamespaceDefItems path n (init items) []) Right
      IndDef (Name n) ty [] -> mkEx EditorBlankCon (PIndDefAddCon path n ty [] []) Right
      IndDef (Name n) ty cons -> mkEx ((\(Name n, t) -> Con n t) $ last cons) (PIndDefCons path n ty (map (\(Name n, t) -> Con n t) $ init cons) []) Right
    FCon focus -> case focus of
      Con n t -> mkEx t (PConTy path n) Right
      EditorBlankCon -> sideRight
    FName _ -> sideRight
  where
    sideRight = case side of
      Left -> Ex $ state { unSide = Right }
      Right -> Ex state
    sideLeft = case side of
      Left -> Ex state
      Right -> Ex $ state { unSide = Left }

edge :: Direction -> Path a -> Bool
edge d p = case d of
  Left -> case p of
    PTop -> True
    PTermDefName _ _ _ -> True
    PNamespaceDefName _ _ -> True
    PIndDefName _ _ _ -> True
    PConName _ _ -> True
    PLamAddParam _ [] _ _ -> True
    PAppAddTerm _ [] _ -> True
    PLetName _ _ _ _ -> True
    PPiName _ _ _ -> True
    PCode _ -> True
    PQuote _ -> True
    PSplice _ -> True
    _ -> False
  Right -> case p of
    PTop -> True
    PTermDefBody _ _ _ -> True
    PNamespaceDefItems _ _ _ [] -> True
    PNamespaceDefAddItem _ _ _ [] -> True
    PIndDefCons _ _ _ _ [] -> True
    PIndDefAddCon _ _ _ _ [] -> True
    PConTy _ _ -> True
    PLamBody _ _ -> True
    PAppTerms _ _ [] -> True
    PAppAddTerm _ _ [] -> True
    PLetBody _ _ _ _ -> True
    PPiOut _ _ _ -> True
    PCode _ -> True
    PQuote _ -> True
    PSplice _ -> True
    _ -> False

atomic :: Focus a -> Bool
atomic focus = case focus of
  FTerm term -> case term of
    Hole -> True
    EditorBlank -> True
    Var _ -> True
    GVar _ -> True
    U0 -> True
    U1 -> True
    _ -> False
  FItem item -> case item of
    EditorBlankDef -> True
    _ -> False
  FCon con -> case con of
    EditorBlankCon -> True
    _ -> False
  FName _ -> True

putWord16 :: Word16 -> Put
putWord16 = put

putItem :: Item -> Put
putItem item = case item of
  NamespaceDef (Name n) items -> do
    putWord8 0
    putString n
    putWord16 $ fromIntegral (length items)
    loop items
    where
      loop is = case is of
        [] -> pure ()
        i:is -> do
          putItem i
          loop is
  TermDef (Name n) ty body -> do
    putWord8 1
    putString n
    putTerm ty
    putTerm body
  IndDef (Name n) ty cons -> do
    putWord8 2
    putString n
    putTerm ty
    putWord16 $ fromIntegral (length cons)
    loop cons
    where
      loop cs = case cs of
        [] -> pure ()
        (Name n, t):cs -> do
          putString n
          putTerm t
          loop cs

putString :: String -> Put
putString s = do
  putWord16 $ fromIntegral (length s)
  loop s
  where
    loop s = case s of
      [] -> pure ()
      c:cs -> do
        put c
        loop cs

putStrings :: [String] -> Put
putStrings ss = case ss of
  [] -> pure ()
  s:ss -> do
    putString s
    putStrings ss

putTerm :: Term -> Put
putTerm term = case term of
  Var (Name name) -> do
    putWord8 0
    putString name
  GVar (GName name) -> do
    putWord8 1
    putWord16 $ fromIntegral (length name)
    putStrings name
  Lam names body -> do
    putWord8 2
    putWord16 $ fromIntegral (length names)
    putStrings (map unName names)
    putTerm body
  App lam args -> do
    putWord8 3
    putTerm lam
    putWord16 $ fromIntegral (length args)
    loop args
    where
      loop as = case as of
        [] -> pure ()
        a:as -> do
          putTerm a
          loop as
  Pi (Name name) inTy outTy -> do
    putWord8 5
    putString name
    putTerm inTy
    putTerm outTy
  Let (Name name) def defTy body -> do
    putWord8 6
    putString name
    putTerm def
    putTerm defTy
    putTerm body
  U1 -> putWord8 7
  U0 -> putWord8 8
  Code ty -> do
    putWord8 9
    putTerm ty
  Quote e -> do
    putWord8 10
    putTerm e
  Splice e -> do
    putWord8 11
    putTerm e
  Hole -> putWord8 12

export :: EditorState a -> String -> IO ()
export state@(EditorState cursor _ _) fn = do
  let program = loop (Ex state) 
  let bs = runPut $ putItem program
  handle <- openFile fn WriteMode
  LB.hPut handle bs
  hClose handle
  where
    loop :: Ex -> Item
    loop (Ex state) =
      case run (MoveOut Left) state of
        ex@(Ex (EditorState (Cursor focus path) _ _)) -> case path of
          PTop -> case focus of FItem item -> item
          _ -> loop ex

render :: EditorState a -> T.Text
render (EditorState (Cursor focus path) _ side) =
  let
    sfocus = renderFocus focus
  in renderPath
    (case side of
      Left -> "\ESC[32;1m{\ESC[0m" <> sfocus <> "\ESC[32;1m]\ESC[0m"
      Right -> "\ESC[32;1m[\ESC[0m" <> sfocus <> "\ESC[32;1m}\ESC[0m")
    (simpleFocus focus)
    path
    <> "\ESC[0m" where
  renderFocus :: Focus a -> T.Text
  renderFocus focus = case focus of
    FName s -> T.pack s
    FTerm term -> renderTerm term
    FItem item -> renderItem item
    FCon (Con name ty) -> T.pack name <> " : " <> renderTerm ty
    FCon EditorBlankCon -> "_"
  renderTerm :: Term -> T.Text
  renderTerm term = case term of
    Lam names body -> "\ESC[35;1mλ\ESC[39m" <> snames (map unName names) <> " ⇒ " <> renderTerm body
    App lam args ->
      let se = if simple lam then renderTerm lam else "(" <> renderTerm lam <> ")"
      in se <> space args <> sterms args
    Var (Name s) -> T.pack s
    GVar (GName ns) -> mconcat $ intersperse "/" $ reverse (map T.pack ns)
    Hole -> "?"
    Let (Name name) def defTy body -> renderLet (T.pack name) (renderTerm defTy) (renderTerm def) (renderTerm body)
    Pi (Name "_") inTy outTy -> renderTerm inTy <> " \ESC[36;1m→\ESC[39m " <> renderTerm outTy
    Pi (Name name) inTy outTy -> "\ESC[36;1mΠ\ESC[39m" <> T.pack name <> " : " <> renderTerm inTy <> ". " <> renderTerm outTy
    U0 -> "\ESC[36;1mU0\ESC[39m"
    U1 -> "\ESC[36;1mU1\ESC[39m"
    Code ty -> "\ESC[36;1mCode\ESC[39m " <> parenFocus (simple ty) (renderTerm ty)
    Quote e -> "\ESC[35;1m‹\ESC[39m" <> renderTerm e <> "\ESC[35;1m›\ESC[39m"
    Splice e -> "\ESC[35;1m~\ESC[39m" <> parenFocus (simple e) (renderTerm e)
    EditorBlank -> "_"
  renderItem :: Item -> T.Text
  renderItem item = case item of
    TermDef (Name n) ty body -> "\ESC[33;1mdef\ESC[39m " <> T.pack n <> " : " <> renderTerm ty <> " ≡ " <> (indent $ renderTerm body)
    NamespaceDef (Name n) items -> "\ESC[33;1mnamespace\ESC[39m " <> T.pack n <> indentForced (sitems items)
    IndDef (Name n) ty cons -> "\ESC[33;1minductive\ESC[39m " <> T.pack n <> " : " <> renderTerm ty <> (indentForced $ scons (map (\(Name n, t) -> Con n t) cons))
    EditorBlankDef -> "_"
  renderPath :: T.Text -> Bool -> Path a -> T.Text
  renderPath focus isSimple path = case path of
    PTop -> focus
    PLamBody up names -> renderPath ("\ESC[35;1mλ\ESC[39m" <> snames names <> " ⇒ " <> focus) False up
    PLamParams up ln rn body -> renderPath ("\ESC[35;1mλ\ESC[39m" <> snames ln <> focus <> snames rn <> " ⇒ " <> renderTerm body) False up
    PLamAddParam up ln rn body -> renderPath ("\ESC[35;1mλ\ESC[39m" <> snames ln <> focus <> snames rn <> " ⇒ " <> renderTerm body) False up
    PAppTerms up le re -> renderApp up le re isSimple focus
    PAppAddTerm up le re -> renderApp up le re isSimple focus
    PLetName up def defTy body -> renderPath (renderLet focus (renderTerm defTy) (renderTerm def) (renderTerm body)) False up
    PLetDef up name defTy body -> renderPath (renderLet (T.pack name) (renderTerm defTy) focus (renderTerm body)) False up
    PLetDefTy up name def body -> renderPath (renderLet (T.pack name) focus (renderTerm def) (renderTerm body)) False up
    PLetBody up name def defTy -> renderPath (renderLet (T.pack name) (renderTerm defTy) (renderTerm def) focus) False up
    PTermDefName up ty body -> renderPath ("\ESC[33;1mdef\ESC[39m " <> focus <> " : " <> renderTerm ty <> " ≡ " <> indent (renderTerm body)) False up
    PTermDefTy up name body -> renderPath ("\ESC[33;1mdef\ESC[39m " <> T.pack name <> " : " <> focus <> " ≡ " <> indent (renderTerm body)) False up
    PTermDefBody up name ty -> renderPath ("\ESC[33;1mdef\ESC[39m " <> T.pack name <> " : " <> renderTerm ty <> " ≡ " <> indent focus) False up
    PNamespaceDefName up items -> renderPath ("\ESC[33;1mnamespace\ESC[39m " <> focus <> indentForced (sitems items)) False up
    PNamespaceDefItems up name li ri -> renderNamespace up (T.pack name) li ri focus
    PNamespaceDefAddItem up name li ri -> renderNamespace up (T.pack name) li ri focus
    PPiName up inTy outTy -> renderPath ("\ESC[36;1mΠ\ESC[39m" <> focus <> " : " <> renderTerm inTy <> ". " <> renderTerm outTy) False up
    PPiIn up name outTy -> renderPi up (T.pack name) focus (renderTerm outTy)
    PPiOut up name inTy -> renderPi up (T.pack name) (renderTerm inTy) focus
    PCode up -> renderPath ("\ESC[36;1mCode\ESC[39m " <> parenFocus isSimple focus) False up
    PQuote up -> renderPath ("\ESC[35;1m‹\ESC[39m" <> focus <> "\ESC[35;1m›\ESC[39m") True up
    PSplice up -> renderPath ("\ESC[35;1m~\ESC[39m" <> parenFocus isSimple focus) isSimple up
    PIndDefName up ty cons -> renderPath ("\ESC[33;1minductive\ESC[39m " <> focus <> " : " <> renderTerm ty <> (indentForced $ scons cons)) False up
    PIndDefTy up name cons -> renderPath ("\ESC[33;1minductive\ESC[39m " <> T.pack name <> " : " <> focus <> (indentForced $ scons cons)) False up
    PIndDefCons up name ty lc rc -> renderCons up (T.pack name) ty lc rc focus
    PIndDefAddCon up name ty lc rc -> renderCons up (T.pack name) ty lc rc focus
    PConName up ty -> renderPath (focus <> " : " <> renderTerm ty) False up
    PConTy up name -> renderPath (T.pack name <> " : " <> focus) False up

  renderCons up name ty lc rc focus = renderPath ("\ESC[33;1minductive\ESC[39m " <> name <> " : " <> renderTerm ty <> indentForced cons) False up
    where
      cons = scons lc <> focus <> newline rc <> scons rc
  renderPi up name inTy outTy = (\s -> renderPath s False up) $ case name of
      "_" -> inTy <> " \ESC[36;1m→\ESC[39m " <> outTy
      _ -> "\ESC[36;1mΠ\ESC[39m" <> name <> " : " <> inTy <> ". " <> outTy
  renderNamespace up name li ri focus = renderPath ("\ESC[33;1mnamespace\ESC[39m " <> name <> indentForced (sitems li <> newline li <> focus <> newline ri <> sitems ri)) False up
  renderLet name ty def body = "\ESC[33;1mlet\ESC[39m " <> name <> case (multiline ty, multiline def, multiline body) of
    (False, False, False) -> " : " <> ty <> " ≡ " <> def <> inStringSpace <> body
    (False, False, True) -> " : " <> ty <> " ≡ " <> def <> inString <> indent body
    (False, True, False) -> " : " <> ty <> "\n  ≡" <> indent2 def <> inStringSpace <> body
    (False, True, True) -> " : " <> ty <> "\n  ≡" <> indent2 def <> inString <> indent body
    (True, False, False) -> "\n  :" <> indent2 ty <> "\n  ≡ " <> def <> inStringSpace <> body
    (True, False, True) -> "\n  :" <> indent2 ty <> "\n  ≡ " <> def <> inString <> indent body
    (True, True, False) -> "\n  :" <> indent2 ty <> "\n  ≡" <> indent2 def <> inStringSpace <> body
    (True, True, True) -> "\n  :" <> indent2 ty <> "\n  ≡" <> indent2 def <> inString <> indent body
    where
      inString = "\n\ESC[33;1min\ESC[39m"
      inStringSpace = inString <> " "
  renderApp up le re isSimple focus = renderPath (sterms le <> space le <> parenFocus isSimple focus <> space re <> sterms re) False up
  parenFocus isSimple focus = if isSimple then focus else "(" <> focus <> ")"
  
  simpleFocus :: Focus a -> Bool
  simpleFocus focus = case focus of
    FName _ -> True
    FTerm term -> simple term
  
  simple term = case term of
    Var _ -> True
    Hole -> True
    U0 -> True
    U1 -> True
    GVar _ -> True
    Quote _ -> True
    Splice e -> simple e
    EditorBlank -> True
    _ -> False
  multiline s = length (T.lines s) /= 1
  space xs = case xs of
    [] -> ""
    _ -> " "
  newline cs = case cs of
    [] -> ""
    _ -> "\n"
  sterms es = case es of
    [] -> ""
    e:es ->
      let se = if simple e then renderTerm e else "(" <> renderTerm e <> ")"
      in se <> space es <> sterms es
  snames ns = mconcat $ intersperse " " (map T.pack ns)
  sitems is = case is of
    [] -> ""
    [i] -> renderItem i
    i:is -> renderItem i <> "\n" <> sitems is
  scons cs = case cs of
    [] -> ""
    (Con n ty):cs -> T.pack n <> " : " <> renderTerm ty <> "\n" <> scons cs
  indent :: T.Text -> T.Text
  indent s =
    if not (multiline s) then
      s
    else
      "\n" <> indentBase s
  indent2 :: T.Text -> T.Text
  indent2 s =
    if not (multiline s) then
      s
    else
      "\n" <> (indentBase . indentBase) s
  indentBase :: T.Text -> T.Text
  indentBase s =
    if not (multiline s) then
      s
    else
      (mconcat $ intersperse "\n" $ map ("  "<>) (T.lines s))
  indentForced :: T.Text -> T.Text
  indentForced s = (if s == "" then "" else "\n") <> (mconcat $ intersperse "\n" $ map ("  "<>) (T.lines s))

-- Lol just Ctrl+C + Ctrl+V from StackOverflow. `hSetBuffering stdin NoBuffering` doesn't work on Windows.
getHiddenChar = fmap (chr.fromEnum) c_getch
foreign import ccall unsafe "conio.h getch"
  c_getch :: IO CInt

data TermInsertionType
  = TILam
  | TILet
  | TIApp
  | TIPi
  | TICode
  | TIQuote
  | TISplice
  deriving Eq

data Input
  = IQuit
  | IExportFile
  | ILoadFile
  | IThenMoveHardRight (Maybe Input)
  | IThenMoveRight (Maybe Input)
  | IThenMoveLeft (Maybe Input)
  | IInsertTermDef
  | IInsertIndDef
  | IInsertNamespaceDef
  | IInsertTerm TermInsertionType
  -- | IInsertLam
  -- | IInsertLet
  -- | IInsertApp
  -- | IInsertPi
  -- | IInsertCode
  -- | IInsertQuote
  -- | IInsertSplice
  | IInsertU0
  | IInsertU1
  | IAdd
  | IInsertCon
  | ISetName String
  deriving Eq

getCommand :: String -> IO Input
getCommand acc = do
  putStr "\ESC[2K"
  putStr "\ESC[1000D"
  putStr (reverse acc)
  hFlush stdout
  c <- getHiddenChar
  case c of
    '\b' -> getCommand (if null acc then [] else tail acc)
    _ -> case parseCommand (c:acc) of
      Just cmd -> pure cmd
      Nothing -> getCommand (c:acc)

split :: String -> String -> Char -> [String]
split s acc d = case s of
  [] -> [acc]
  c:cs ->
    if c == d then
      acc : split cs "" d
    else
      split cs (acc ++ [c]) d

parseCommand :: String -> Maybe Input
parseCommand s = case s of
  "q;" -> Just $ IQuit
  "]" -> Just $ IThenMoveRight Nothing
  "[" -> Just $ IThenMoveLeft Nothing
  "mi;" -> Just $ ILoadFile
  "xe;" -> Just $ IExportFile
  "." -> Just $ IThenMoveRight $ Just $ IInsertTerm $ TIApp
  " >-" -> Just $ IThenMoveHardRight $ Just $ IThenMoveRight $ Just $ IThenMoveRight $ Just $ IInsertTerm $ TIPi
  " llarof" -> Just $ IThenMoveRight $ Just $ IInsertTerm $ TIPi
  " fed" -> Just $ IThenMoveRight $ Just $ IInsertTermDef
  " tel" -> Just $ IThenMoveRight $ Just $ IInsertTerm $ TILet
  " 0u" -> Just $ IThenMoveRight $ Just IInsertU0
  " 1u" -> Just $ IThenMoveRight $ Just IInsertU1
  "\\" -> Just $ IThenMoveRight $ Just $ IInsertTerm $ TILam
  " " -> Just $ IThenMoveRight $ Just IAdd
  " edoc" -> Just $ IThenMoveRight $ Just $ IInsertTerm $ TICode
  "<" -> Just $ IThenMoveRight $ Just $ IInsertTerm $ TIQuote
  "~" -> Just $ IThenMoveRight $ Just $ IInsertTerm $ TISplice
  " dni" -> Just $ IThenMoveRight $ Just IInsertIndDef
  " sn" -> Just $ IThenMoveRight $ Just IInsertNamespaceDef
  "#" -> Just $ IThenMoveRight $ Just IInsertCon
  ' ':s -> Just $ IThenMoveRight $ Just $ ISetName (reverse s)
  _ -> Nothing

moveRight state = (\c -> run c state) $ case (edge Right (unPath $ unCursor state), atomic (unFocus $ unCursor state), unSide state) of
  (False, False, Left) -> MoveInLeft
  (False, True, Left) -> MoveRight
  (True, False, Left) -> MoveInLeft
  (True, True, Left) -> MoveRight
  (False, False, Right) -> MoveRight
  (False, True, Right) -> MoveRight
  (True, False, Right) -> MoveOut Right
  (True, True, Right) -> MoveOut Right

moveLeft state = (\c -> run c state) $ case (edge Left (unPath $ unCursor state), atomic (unFocus $ unCursor state), unSide state) of
  (False, False, Left) -> MoveLeft
  (False, True, Left) -> MoveLeft
  (True, False, Left) -> MoveOut Left
  (True, True, Left) -> MoveOut Left
  (False, False, Right) -> MoveInRight
  (False, True, Right) -> MoveLeft
  (True, False, Right) -> MoveInRight
  (True, True, Right) -> MoveLeft

handleInput :: EditorState a -> Input -> IO Ex
handleInput state input = case (input, unFocusType state) of
  (IExportFile, _) -> do
    fn <- getLine
    export state fn
    pure $ Ex state
  (ILoadFile, _) -> do
    fn <- getLine
    handle <- openFile fn ReadMode
    bs' <- LB.hGetContents handle
    let !bs = bs'
    let program = runGet getItem bs
    hClose handle
    pure $ mkEx program PTop Left
  (IThenMoveHardRight input', _) -> do
    (Ex state') <- case input' of
      Just input' -> handleInput state input'
      Nothing -> pure $ Ex state
    pure $ run MoveRight state'
  (IThenMoveRight input', _) -> do
    (Ex state') <- case input' of
      Just input' -> handleInput state input'
      Nothing -> pure $ Ex state
    pure $ moveRight state'
  (IThenMoveLeft input', _) -> do
    (Ex state') <- case input' of
      Just input' -> handleInput state input'
      Nothing -> pure $ Ex state
    pure $ moveLeft state'
  -- ("al", _) -> pure $ run (Add Left) state
  (IAdd, _) -> pure $ run Add state
  -- ("d", FTTerm) -> pure $ run InsertHole state
  (IInsertTerm ti, FTTerm) -> pure $ run (InsertTerm ti) state
  (IInsertU0, FTTerm) -> pure $ run InsertU0 state
  (IInsertU1, FTTerm) -> pure $ run InsertU1 state
  (IInsertNamespaceDef, FTItem) -> pure $ run InsertNamespaceDef state
  (IInsertTermDef, FTItem) -> pure $ run InsertTermDef state
  (IInsertIndDef, FTItem) -> pure $ run InsertIndDef state
  (IInsertCon, FTCon) -> pure $ run InsertCon state
  (ISetName s, FTTerm) -> case split s "" '/' of
    [] -> pure $ run (InsertVar s) state
    ns -> pure $ run (InsertGVar $ reverse ns) state 
  (ISetName s, FTName) -> pure $ if s == "" then Ex state else run (SetName s) state
  _ -> pure $ Ex state

loop :: EditorState a -> IO ()
loop state = do
  clearScreen
  putStrLn (show state)
  TIO.putStrLn (render state)
  input <- getCommand ""
  if input == IQuit then
    pure ()
  else do
    state <- handleInput state input
    next state
    where
      next :: Ex -> IO ()
      next (Ex state) = loop state

main :: IO ()
main = do
  setLocaleEncoding utf8
  putStr "\ESC[0m"
  loop (EditorState (Cursor (FName "main") (PNamespaceDefName PTop [])) FTName Left)
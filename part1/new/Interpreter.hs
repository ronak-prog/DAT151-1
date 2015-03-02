{-# LANGUAGE RankNTypes #-}
module Interpreter where

import AbsCPP
import PrintCPP
import ErrM

import Control.Monad
import Control.Monad.IO.Class
import qualified Data.Map as M
import Data.IORef
import Data.Maybe

data Val
  = VInt Int
  | VDouble Double
  | VBool Bool
  | VVoid
  | VUndefined
  deriving Show

data Fun = Fun [Id] [Stm]
type Env = (M.Map Id Fun, [IORef (M.Map Id Val)])

interpret :: Program -> IO ()
interpret (PDefs defs) = do
  -- Build initial environment with all function definitions.
  let argToId (ADecl _ id) = id
      dfunToFun (DFun _ i args stms) = (i, Fun (map argToId args) stms)
      defs' = map dfunToFun defs
      env = (M.fromList $ defs', [])
  invoke env (Id "main") []
  return ()

exec :: Env -> Stm -> IO (Maybe Val)
exec env (SExp e) = do
  up $ eval env e
  nothing
exec env (SDecls t ids) = do
  forM_ ids $ \i -> addVar env i VUndefined
  nothing
exec env (SInit t i e) = do
  eval env e >>= addVar env i
  nothing
exec env (SReturn e) = do 
  up $ eval env e
exec env s@(SWhile e stm) = do
  cond <- eval env e
  case cond of
    (VBool True) -> do
      exec env stm
      exec env s
    _ -> return Nothing
exec env (SBlock stms) = do
  execStms env stms
exec env (SIfElse e stma stmb) = do
  cond <- liftIO $ eval env e
  case cond of
    (VBool True) -> exec env stma
    (VBool False) -> exec env stmb

execStms :: Env -> [Stm] -> IO (Maybe Val)
execStms env stms = do
  env' <- liftIO $ newFrame env
  execStms' env' stms

execStms' :: Env -> [Stm] -> IO (Maybe Val)
execStms' env [] = return Nothing
execStms' env (stm:stms) = do
  value <- exec env stm
  case value of
    Nothing  -> execStms' env stms
    Just x -> return (Just x)

eval :: Env -> Exp -> IO Val
eval env expr =
  case expr of
    ETrue -> return $ VBool True
    EFalse -> return $ VBool False
    EInt i -> return $ VInt $ fromIntegral i
    EDouble d -> return $ VDouble d
    EId i -> do
      val <- getVar env i
      case val of
        VUndefined -> error $ "Undefined variable " ++ show i
        _ -> return val
    EApp i args -> invoke env i args
    EPDecr e -> evalPost (\n -> n - 1) (\n -> n - 1) e
    EPIncr e -> evalPost (1 +) (1 +) e
    EDecr e -> evalPre (\n -> n - 1) (\n -> n - 1) e
    EIncr e -> evalPre (1 +) (1 +) e
    ETimes a b -> evalBinOp (*) (*) a b
    EDiv a b -> evalBinOp (/) quot a b
    EPlus a b -> evalBinOp (+) (+) a b
    EMinus a b -> evalBinOp (-) (-) a b
    ELt a b -> evalCompBinOp (<) (<) a b
    EGt a b -> evalCompBinOp (>) (>) a b
    ELtEq a b -> evalCompBinOp (<=) (<=) a b
    EGtWq a b -> evalCompBinOp (>=) (>=) a b
    EEq a b -> evalCompBinOp (==) (==) a b
    ENEq a b -> evalCompBinOp (/=) (/=) a b
    EAnd a b -> evalAndOp a b
    EOr a b -> evalOrOp a b
    EAss (EId a) b -> do
      b' <- eval env b
      setVar env a b'
      return b'
  where
    evalPre fd fi (EId i) = do
      updateNumVar env fd fi i
      getVar env i
    evalPost fd fi (EId i) = do
      current <- getVar env i
      updateNumVar env fd fi i
      return current
    evalBinOp fd fi a b = do
      a' <- eval env a
      b' <- eval env b
      return $ case (a', b') of
        ((VDouble va), (VDouble vb)) -> VDouble $ fd va vb
        ((VInt va), (VInt vb)) -> VInt $ fi va vb
    evalCompBinOp fd fi a b = do
      a' <- eval env a
      b' <- eval env b
      return $ case (a', b') of
        ((VDouble va), (VDouble vb)) -> VBool $ fd va vb
        ((VInt va), (VInt vb)) -> VBool $ fi va vb
    evalAndOp a b = do
      (VBool a') <- eval env a
      if a' then eval env b else return $ VBool False
    evalOrOp a b = do
      (VBool a') <- eval env a
      if a' then return $ VBool True else eval env b

invoke :: Env -> Id -> [Exp] -> IO Val
invoke env@(funs, frames) i argExps = do
  argVals <- mapM (eval env) argExps
  case (i,argVals) of
    (Id "printInt", [arg1]) -> do
      putStrLn $ prettyVal arg1
      return VVoid
    (Id "printDouble", [arg1]) -> do
      putStrLn $ prettyVal arg1
      return VVoid
    (Id "readInt", []) -> do
      val <- readLn
      return $ VInt val
    (Id "readDouble", []) -> do
      val <- readLn
      return $ VInt val
    _ -> do
      let (Fun args body) = lookupFun env i
      newEnv <- emptyEnv funs
      (forM_ (zip args argVals) $ \(arg, val) -> addVar newEnv arg val)
      d <- execStms newEnv body
      return $ convert d

emptyEnv funs = do
  initFrame <- newIORef M.empty
  return (funs, [initFrame])

up :: IO Val -> IO (Maybe Val)
up x = fmap Just x

nothing :: IO (Maybe Val)
nothing = return Nothing

convert :: Maybe Val -> Val
convert (Just val) = val
convert Nothing = VVoid

newFrame :: Env -> IO Env
newFrame (fs, vs) = do
  ref <- newIORef M.empty
  return (fs, ref : vs)

lookupFun :: Env -> Id -> Fun
lookupFun (funs, _) i = lookupId i funs

lookupId :: Id -> M.Map Id v -> v
lookupId i@(Id iStr) m =
  let maybeV = M.lookup i m
  in case maybeV of
    Just v -> v
    Nothing -> error $ "Id not found " ++ iStr

addVar, setVar :: Env -> Id -> Val -> IO ()
addVar (_, frameRef:_) i val =
  modifyIORef frameRef (M.insert i val)
setVar (_, []) i _ = error $ "Unbound variable " ++ show i
setVar (funs, frameRef:restRefs) i val = do
  frame <- readIORef frameRef
  if (M.member i frame)
    then writeIORef frameRef $ M.insert i val frame
    else setVar (funs, restRefs) i val

getVar :: Env -> Id -> IO Val
getVar (_, frameRefs) i = do
  frames' <- mapM readIORef frameRefs
  case catMaybes $ map (M.lookup i) frames' of
    []      -> error $ "Unbound variable " ++ show i
    (v : _) -> return v

updateNumVar :: Env -> (Double -> Double) -> (Int -> Int) -> Id -> IO ()
updateNumVar env fd fi i = do
  val <- getVar env i
  case val of
    VDouble d -> setVar env i $ VDouble $ fd d
    VInt d -> setVar env i $ VInt $ fi d

prettyVal :: Val -> String
prettyVal v = case v of
  VInt i      -> show i
  VDouble d   -> show d
  VBool True  -> "true"
  VBool False -> "false"
  VVoid       -> "void"
  VUndefined  -> "undefined"
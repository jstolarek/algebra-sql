{-# LANGUAGE TypeSynonymInstances#-}
module Ferry.Front.Convert.Normalise where

import Ferry.Front.Data.Language
import Ferry.Front.Data.Base
import Ferry.Front.Data.Meta
import Ferry.Front.Data.Instances
import Ferry.Compiler.Error.Error

import Control.Monad.State
import Control.Monad.Error
import qualified Data.Map as M
import qualified Data.List as L
import Control.Applicative (Applicative(..), (<**>), (<$>), (<*>))

-- Everything we normalise is member of the normalise class
class Normalise a where
    normalise :: a -> Transformation a
    
-- Substitutions are stored in a map, a variable name is always substituted by a new one
type Substitution = M.Map Identifier Expr

-- The transformation monad
-- The outcome is a pair of the outcome or an error and a state.
-- The state contains substitutions and a supply of fresh variables
type Transformation = ErrorT FerryError (State (Int, Substitution))

instance Applicative Transformation where
    (<*>) = ap
    pure = return
    
restoreState :: Transformation a -> Transformation a
restoreState e = do
                    (_, s) <- get
                    e' <- e
                    (c, _) <- get
                    put (c, s)
                    return e'
    
-- Convenience function for operations on the monad

-- Add a substitution
addSubstitution :: Identifier -> Expr -> Transformation ()
addSubstitution i n = do
                        modify (\(v, m) ->  (v, M.insert i n m))

-- Apply a substitution to the given identifier
applySubstitution :: Expr -> Transformation Expr
applySubstitution v@(Var _ i) = do
                        (_,m) <- get
                        case M.lookup i m of
                            Nothing -> return v
                            Just i' -> return i'

-- Remove the list of given identifiers from the substitution list
removeSubstitution :: [Identifier] -> Transformation ()
removeSubstitution is = do
                         modify (\(v, m) -> (v, foldr M.delete m is))

-- Retrieve a fresh variable name from the monad, the state is updated accordingly                         
getFreshIdentifier :: Transformation String
getFreshIdentifier = do
                        (n, subst) <- get
                        put (n + 1, subst)
                        return $ "_v" ++ show n

-- Retrieve a fresh variable from the monad                        
getFreshVariable :: Transformation Expr
getFreshVariable = do
                    n <- getFreshIdentifier
                    return $ Var (Meta emptyPos) n

-- Transform the given expression
runTransformation :: Normalise a => a -> Either FerryError a
runTransformation x = fst $ flip runState (0, M.empty) $ runErrorT $ (normalise x)

-- Instances of the normalise class

instance Normalise Arg where
    normalise (AExpr m e) = do
                             e' <- normalise e
                             return $ AExpr m e'
    normalise (AAbstr m p e) = restoreState $
                                do
                                 let vs = vars p
                                 removeSubstitution vs
                                 e' <- normalise e
                                 return $ AAbstr m p e'

instance Normalise RecElem where
    normalise r@(TrueRec m s e) = 
                                case (s, e) of
                                 (Right i, Just ex) -> (\e' -> TrueRec m s $ Just e') <$> normalise ex
                                 (Right i, Nothing) -> pure $ TrueRec m s $ Just (Var m i)
                                 (Left i, Nothing) -> case i of
                                                        (Elem m e (Left x)) -> (\i' -> TrueRec m (Right x) $ Just i') <$> normalise i
                                                        (_)                 ->  throwError $ IllegalRecSyntax r
                                 (_) -> throwError $ IllegalRecSyntax r
    normalise (TuplRec m i e) = TuplRec m i <$> normalise e

instance Normalise Binding where
    normalise (Binding m s e) = do
                                 e' <- normalise e
                                 removeSubstitution [s]
                                 return $ Binding m s e'

instance Normalise Expr where
    normalise c@(Const _ _) = return c
    normalise (UnOp m o e) = UnOp m o <$> normalise e
    normalise (BinOp m o e1 e2) = BinOp m o <$> normalise e1 <*> normalise e2
    normalise v@(Var m i) = applySubstitution v
    normalise (App m e a) = do 
                             v <- getFreshIdentifier 
                             case e of
                              (Var m "lookup") -> normalise $ Elem m ex $ Right 2                                                 
                               where
                                   ex = App m (Var m "single") [AExpr m filterApp]
                                   filterApp = App m (Var m "filter") [AAbstr m (PVar m v) comp, AExpr m el]
                                   comp = BinOp m (Op m "==") (Elem m (Var m v) $ Right 1) ek
                                   [e1, e2] = a 
                                   el = case e2 of
                                         AExpr _ e' -> e'
                                   ek = case e1 of
                                         AExpr _ e' -> e'
                              _ -> App m <$> normalise e <*> mapM normalise a
    normalise (If m e1 e2 e3) =  If m <$> normalise e1 <*> normalise e2 <*> normalise e3
    normalise (Record  m els) = case (head els) of
                                 (TrueRec _ _ _) ->
                                    (\e -> Record m $ L.sortBy sortElem e) <$>  mapM normalise els
                                 (TuplRec _ _ _) -> Record m <$> mapM normalise els
    normalise (Paren _ e) = normalise e
    normalise (List m es) = List m <$> mapM normalise es
    normalise (Elem m e i) = Elem m <$> normalise e <*> return i
    normalise (Lookup m e1 e2) = normalise $ App m (Var m "lookup") [AExpr (getMeta e2) e2, AExpr (getMeta e1) e1]
    normalise (Let m bs e) = restoreState $ 
                              case bs of
                                [b] -> (\b' n -> Let m [b'] n) <$> normalise b <*> normalise e
                                (b:bss) -> (\b' tl -> Let m [b'] tl) <$> normalise b <*> (normalise $ Let m bss e)
    normalise (Table m s cs ks) = pure $ Table m s (L.sortBy sortColumn cs) ks
    normalise (Relationship m c1 e1 c2 e2 k1 k2) = do
                    v1 <- getFreshIdentifier
                    v2 <- getFreshIdentifier
                    cg <- compgen v1 v2 k1 k2
                    let filterF = AAbstr m (PVar m v2) cg
                    let filterApp = App m (Var m "filter") [filterF, AExpr m e2]
                    case (c1, c2) of
                        (One _, One _) -> do                                            
                                            let single = App m (Var m "single") [AExpr m filterApp]  
                                            normalise $ App m (Var m "map") [ AAbstr m (PVar m v1) 
                                                                                       (Record m [ TuplRec m 1 (Var m v1)
                                                                                                 , TuplRec m 2 single
                                                                                                 ])
                                                                            , AExpr m e1]
                        (One _, Many _) -> do
                                             normalise $ App m (Var m "map") [ AAbstr m (PVar m v1) 
                                                                                        (Record m [ TuplRec m 1 (Var m v1)
                                                                                                  , TuplRec m 2 filterApp
                                                                                                  ])
                                                                             , AExpr m e1]
    normalise (QComp m q) = QComp m <$> normalise q
    
compgen :: String -> String -> Key -> Key -> Transformation Expr
compgen v1 v2 k1@(Key m1 ks1) k2@(Key m2 ks2) = if (length ks1 == length ks2)
                                                 then pure $ foldl1 ands $ zipWith equal v1s v2s
                                                 else throwError $ IncompatableKeys k1 k2
    where
        ands = (\e1 e2 -> BinOp m1 (Op m1 "and") e1 e2)
        equal = (\e1 e2 -> BinOp m1 (Op m1 "==") e1 e2)
        rec1 = (\f -> Elem m1 (Var m1 v1) $ Left f)
        v1s = [rec1 k | k <- ks1]
        rec2 = (\f -> Elem m2 (Var m2 v2) $ Left f)
        v2s = [rec2 k | k <- ks2]
        
sortColumn :: Column -> Column -> Ordering
sortColumn (Column _ s1 _) (Column _ s2 _) = compare s1 s2

sortElem :: RecElem -> RecElem -> Ordering
sortElem (TrueRec _ (Right i1) _) (TrueRec _ (Right i2) _) = compare i1 i2
sortElem _                        _                        = error "illegal input to sortElem Normalise.hs"


instance Normalise QCompr where
    normalise (FerryCompr m bs bd r) = restoreState $ if length bs > 1
                                                        then undefined
                                                        else undefined
                                        
    normalise (HaskellCompr _) = error "Not implemented HaskellCompr"


normalise' :: (Pattern, Expr) -> (Pattern, Expr) -> Transformation (Pattern, Expr)
normalise' (p1, e1) (p2, e2) = do
                                 star <- getFreshIdentifier
                                 pure $ (PVar m star, rExpr)                                 
    where m = Meta emptyPos
          v1s = case p1 of
                 PVar _ s -> [s]
                 PPat _ vs -> vs
          v2s = case p2 of
                 PVar _ s -> [s]
                 PPat _ vs -> vs
          rExpr = App m (Var m "concatMap" ) [arg1, arg2, arg3]
          arg1 = AAbstr m p1 e2
          arg2 = undefined
          arg3 = undefined
                    
{-

PVar :: Meta -> String -> Pattern
PPat :: Meta -> [String] -> Pattern
data QCompr where
    FerryCompr     :: Meta -> [(Pattern, Expr)] -> [BodyElem] -> ReturnElem -> QCompr
    HaskellCompr :: Meta -> QCompr
     deriving (Show, Eq)

data BodyElem where
    For :: Meta -> [(Pattern, Expr)] -> BodyElem
    ForLet :: Meta -> [(Pattern, Expr)] -> BodyElem
    ForWhere :: Meta -> Expr -> BodyElem
    ForOrder :: Meta -> [ExprOrder] -> BodyElem 
    GroupBy :: Meta -> Maybe Expr -> [Expr] -> Maybe Pattern -> BodyElem
    GroupWith :: Meta -> Maybe Expr -> [Expr] -> Maybe Pattern -> BodyElem
     deriving (Show, Eq)
     
data ReturnElem where
    Return :: Meta -> Expr -> Maybe (Pattern, [BodyElem], ReturnElem) -> ReturnElem
    deriving (Show, Eq)
-}

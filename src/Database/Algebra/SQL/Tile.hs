{-# LANGUAGE DoAndIfThenElse #-}
module Database.Algebra.SQL.Tile
    ( TileTree (TileNode, ReferenceLeaf)
    , TileChildren
    , ExternalReference
    , InternalReference
    , DependencyList
    , TransformResult
    , transform
    , PFDag
    , -- TODO should not export / maybe put in another module which is not
      -- available in public
      emptySelectStmt
    , mkPCol
    , mkFromPartRef
    ) where

-- TODO maybe split this file into the tile definition
--      and the transform things.
-- TODO embed closing tiles as subqueries (are there any sub queries which are
-- correlated?)? (reader?)
-- TODO RowRank <-> DenseRank ?
-- TODO isMultiReferenced special case: check for same parent !! (implement
-- embedding with LATERAL ?

import Control.Monad.Reader
import Control.Monad.State.Lazy
import Control.Monad.Writer.Lazy
import qualified Data.Map.Lazy as Map
import Data.Maybe
import qualified Data.DList as DL
    ( DList
    , singleton
    )

import qualified Database.Algebra.Dag as D
import qualified Database.Algebra.Dag.Common as C
import qualified Database.Algebra.Pathfinder.Data.Algebra as A

import qualified Database.Algebra.SQL.Query as Q

-- | A tile internal reference type.
type InternalReference = Q.ReferenceType

-- | The type used to reference table expressions outside of a tile.
type ExternalReference = Int

-- | Aliased tile children, where the first part is the alias used within the
-- 'Q.SelectStmt'.
type TileChildren = [(InternalReference, TileTree)]

-- | Defines the tile tree structure.
data TileTree = -- | A tile: The first argument determines whether the
                -- 'Q.SelectStmt' has nothing else but the select, from or
                -- where clause/ set and is thus mergeable.
                TileNode Bool Q.SelectStmt TileChildren
                -- | A reference pointing to another TileTree: The second
                -- argument specifies the columns of the referenced table
                -- expression.
              | ReferenceLeaf ExternalReference [String]

-- | The type of DAG used by Pathfinder.
type PFDag = D.AlgebraDag A.PFAlgebra

-- | Association list (where dependencies should be ordered topologically).
type DependencyList = DL.DList (ExternalReference, TileTree)


-- | A combination of types which need to be modified state wise while
-- transforming:
--     * The processed nodes with multiple parents.
--
--     * The current state of the table id generator.      
--
--     * The current state of the variable id generator.
type TransformState =
    ( Map.Map C.AlgNode (ExternalReference, [String])
    , ExternalReference
    , InternalReference
    )

-- | The initial state.
sInitial :: TransformState
sInitial = (Map.empty, 0, 0)

-- | Adds a new binding to the state.
sAddBinding :: C.AlgNode          -- ^ The key as a node with multiple parents.
            -> ( ExternalReference
               , [String]
               )                  -- ^ Name of the reference and its columns.
            -> TransformState
            -> TransformState
sAddBinding n t (m, g, v) = (Map.insert n t m, g, v)

-- | Tries to look up a binding for a node.
sLookupBinding :: C.AlgNode
               -> TransformState
               -> Maybe (ExternalReference, [String])
sLookupBinding n (m, _, _) = Map.lookup n m

-- | The transform monad is used for transforming from DAGs into the tile plan. It
-- contains:
--     * A writer for outputting the dependencies
--
--     * A reader for the DAG (since we only read from it)
--
--     * A state for generating fresh names and maintain the mapping of nodes
type TransformMonad = WriterT DependencyList
                              (ReaderT PFDag
                                       (State TransformState))

-- | A table expression id generator using the state within the
-- 'TransformMonad'.
generateTableId :: TransformMonad ExternalReference
generateTableId = do
    (_, i, _) <- get

    modify nextState

    return i
  where nextState (m, g, i) = (m, g + 1, i)

generateAliasName :: TransformMonad String
generateAliasName = do
    (_, i, _) <- get

    modify nextState

    return $ 'a' : show i
  where nextState (m, g, i) = (m, g + 1, i)

-- | A variable identifier generator.
generateVariableId :: TransformMonad Int
generateVariableId = do
    (_, _, i) <- get

    modify nextState

    return i
  where nextState (m, g, i) = (m, g, i + 1)

-- | Unpack values (or run computation).
runTransformMonad :: TransformMonad a
                  -> PFDag                      -- ^ The used DAG.
                  -> TransformState             -- ^ The inital state.
                  -> (a, DependencyList)
runTransformMonad m env = evalState readerResult
  where writerResult = runWriterT m
        readerResult = runReaderT writerResult env

-- | Check if node has more than one parent.
isMultiReferenced :: C.AlgNode
           -> PFDag
           -> Bool
isMultiReferenced n dag = case D.parents n dag of
    -- Has at least 2 parents.
    _:(_:_) -> True
    _       -> False

-- | Get the column schema of a 'TileNode'.
getSchemaTileTree :: TileTree -> [String]
getSchemaTileTree (ReferenceLeaf _ s) = s
getSchemaTileTree (TileNode _ body _) = getSchemaSelectStmt body

-- | Get the column schema of a 'Q.SelectStmt'.
getSchemaSelectStmt :: Q.SelectStmt -> [String]
getSchemaSelectStmt s = map Q.sName $ Q.selectClause s

-- | The result of the 'transform' function.
type TransformResult = ([TileTree], DependencyList)

-- | Transform a 'PFDag', while swapping out repeatedly used sub expressions
-- (nodes with more than one parent).
-- A 'PFDag' can have multiple root nodes, and therefore the function returns a
-- list of root tiles and their dependencies.
transform :: PFDag -> TransformResult
transform dag = runTransformMonad result dag sInitial
  where rootNodes = D.rootNodes dag
        result    = mapM transformNode rootNodes

-- | This function basically checks for already referenced nodes with more than
-- one parent, returning a reference to already computed 'TileTree's.
transformNode :: C.AlgNode -> TransformMonad TileTree 
transformNode n = do

    op <- asks $ D.operator n

    -- allowBranch indicates whether multi reference nodes shall be split
    -- for this operator, resulting in multiple equal branches. (Treeify)
    let (allowBranch, transformOp) = case op of
                                   -- Ignore branching for nullary operators.
            (C.NullaryOp nop)   -> (False, transformNullaryOp nop)
            (C.UnOp uop c)      -> (True, transformUnOp uop c)
            (C.BinOp bop c0 c1) -> (True, transformBinOp bop c0 c1)
            (C.TerOp () _ _ _)  ->
                ( True
                , fail "transformOperator: invalid operator type TerOp found"
                )

    if allowBranch
    then do
       
        multiRef <- asks $ isMultiReferenced n

        if multiRef
        then do
            -- Lookup whether there exists a binding for the node in the current
            -- state.
            possibleBinding <- gets $ sLookupBinding n

            case possibleBinding of
                -- If so, just return it.
                Just (b, s) -> return $ ReferenceLeaf b s
                -- Otherwise add it.
                Nothing     -> do

                    result <- transformOp

                    -- Generate a name for the sub tree.
                    tableId <- generateTableId

                    -- Add the tree to the writer.
                    tell $ DL.singleton (tableId, result)

                    let schema = getSchemaTileTree result

                    -- Add binding for this node (to prevent recalculation).
                    modify $ sAddBinding n (tableId, schema)

                    return $ ReferenceLeaf tableId schema
        else transformOp

    -- Transform the operator into a TileTree.
    else transformOp

transformNullaryOp :: A.NullOp -> TransformMonad TileTree
transformNullaryOp (A.LitTable tuples schema) = do
    alias <- generateAliasName

    let sFun n   = Q.SCAlias (Q.SEValueExpr $ mkPCol alias n) n
        sClause  = map (sFun . fst) schema
        fLiteral = Q.FPAlias (Q.FESubQuery $ Q.VQLiteral $ map tMap tuples)
                             alias
                             $ Just $ map fst schema

    return $ TileNode
             True
             emptySelectStmt
             { Q.selectClause = sClause
             , Q.fromClause = [fLiteral]
             }
             []
  where tMap = map $ Q.VEValue . translateAVal 

-- | An empty table. (Currently implemented with a row of null values.)
transformNullaryOp (A.EmptyTable schema) = do
    alias <- generateAliasName

    let fLiteral = Q.FPAlias (Q.FESubQuery $ Q.VQLiteral values)
                             alias
                             $ Just $ map fst schema
        body = emptySelectStmt
               { Q.selectClause = map (asSelectColumn alias . fst) schema
               , Q.fromClause = [fLiteral]
               }

    return $ TileNode True body []
        -- A row of null values
  where values = [map (const $ Q.VEValue Q.VNull) schema]
        

transformNullaryOp (A.TableRef (name, info, _))   = do
    alias <- generateAliasName
    
    let f (n, _) = Q.SCAlias (Q.SEValueExpr $ mkPCol alias n) n
        body     =
            emptySelectStmt
            { -- Map the columns of the table reference to the given
              -- column names.
              Q.selectClause = map f info
            , Q.fromClause =
                    [ Q.FPAlias (Q.FETableReference name)
                                alias
                                -- Map to old column name.
                                $ Just $ map fst info 
                    ] 
            }

    return $ TileNode True body []


-- | Abstraktion for rank operators.
transformUnOpRank :: -- SelectExpr constructor.
                     ([Q.OrderExpr] -> Q.SelectExpr)
                  -> (String, A.SortInf)
                  -> C.AlgNode
                  -> TransformMonad TileTree
transformUnOpRank rankConstructor (name, sortList) =
    let colFun sClause = Q.SCAlias
                         ( rankConstructor $ translateInlinedSortInf
                                             sClause
                                             sortList
                         )
                         name
    in attachColFunUnOp colFun (TileNode False)


transformUnOp :: A.UnOp -> C.AlgNode -> TransformMonad TileTree
transformUnOp (A.RowNum (name, sortList, optPart)) c =
    attachColFunUnOp colFun (TileNode False) c
  where colFun sClause = Q.SCAlias rowNumExpr name
          where rowNumExpr = Q.SERowNum
                             (liftM (inlineColumn sClause) optPart)
                             $ translateInlinedSortInf sClause sortList

transformUnOp (A.RowRank inf) c = transformUnOpRank Q.SEDenseRank inf c
transformUnOp (A.Rank inf) c = transformUnOpRank Q.SERank inf c
transformUnOp (A.Project projList) c = do
    
    (select, children) <- transformAsSelect c

    let sClause  = Q.selectClause select
        -- Inlining is obligatory here, since we possibly eliminate referenced
        -- columns. ('translateExpr' inlines columns.)
        f (n, e) = Q.SCAlias (Q.SEValueExpr tE) n
          where tE = translateExpr (Just sClause) e

    return $ TileNode
             True
             -- Replace the select clause with the projection list.
             select { Q.selectClause = map f projList }
             -- But use the old children.
             children


transformUnOp (A.Select expr) c = do

    (select, children) <- transformAsSelect c
    
    return $ TileNode
             True
             ( appendToWhere ( translateExpr
                               (Just $ Q.selectClause select)
                               expr
                             )
               select
             )
             children

-- | Since WHERE is executed before the window functions we have to wrap the
-- window function in a sub query. This makes the outer select statement
-- mergable.
transformUnOp (A.PosSel (pos, sortList, optPart)) c = do
 
    (select, children) <- transformAsSelect c

    alias <- generateAliasName

    let sClause = Q.selectClause select
        inner   = select { Q.selectClause = col : sClause }
        oes     = translateInlinedSortInf sClause sortList
        col     = Q.SCAlias ( Q.SERowNum
                              (liftM (inlineColumn sClause) optPart)
                              oes
                            )
                            colName

    return $ TileNode
             False
             emptySelectStmt
             -- Remove the temporary column.
             { -- Map prefix to inner column prefixes.
               Q.selectClause = columnsFromSchema alias
                                $ getSchemaSelectStmt select
             , Q.fromClause =
                   [mkSubQuery inner alias $ Just $ getSchemaSelectStmt inner]
             , Q.whereClause = Just
                               $ mkEqual 
                                 (mkPCol alias colName)
                                 (Q.VEValue $ Q.VInteger
                                              $ fromIntegral pos)
             }
             children
        -- Since the value is encapsulated it should work. (Tested in
        -- postgresql.)
  where colName = "tmpPos"

transformUnOp (A.Distinct ()) c = do

    (select, children) <- transformAsSelect c

    -- Keep everything but set distinct.
    return $ TileNode False select { Q.distinct = True } children

transformUnOp (A.Aggr (aggrs, partExprMapping)) c = do
    
    (select, children) <- transformAsSelect c

    let sClause         = Q.selectClause select
        translateE      = translateExpr $ Just sClause
        maybeTranslateE = liftM translateE
        -- Inlining here is obligatory, since we could eliminate referenced
        -- columns. (This is similar to projection.)
        aggrToSE (a, n) = Q.SCAlias ( let (fun, optExpr) = translateAggrType a
                                      in Q.SEAggregate (maybeTranslateE optExpr)
                                                       fun
                                    )
                                    n
        wrapSCAlias (name, expr)
                        =
            Q.SCAlias (Q.SEValueExpr $ translateE expr) name

    return $ TileNode
             False
             select
             { Q.selectClause =
                   map wrapSCAlias partExprMapping ++ map aggrToSE aggrs
             , Q.groupByClause = map (translateE . snd) partExprMapping
             }
             children

-- | Generates a new 'TileTree' by attaching a column, generated by a function
-- taking the select clause.
attachColFunUnOp :: ([Q.SelectColumn] -> Q.SelectColumn)
                 -> (Q.SelectStmt -> TileChildren -> TileTree)
                 -> C.AlgNode
                 -> TransformMonad TileTree
attachColFunUnOp colFun ctor child = do

    (select, children) <- transformAsSelect child

    let sClause = Q.selectClause select
    return $ ctor
             -- Attach a column to the select clause generated by the given
             -- function.
             select { Q.selectClause = colFun sClause : sClause }
             children

-- Abstracts over binary set operation operators.
transformBinSetOp :: Q.SetOperation
                  -> C.AlgNode
                  -> C.AlgNode
                  -> TransformMonad TileTree
transformBinSetOp setOp c0 c1 = do

    -- Use one tile to get the schema information.
    (select0, children0) <- transformAsSelect c0
    (select1, children1) <- transformAsSelect c1

    alias <- generateAliasName

    -- Take the schema of the first one, but could also be from the second one,
    -- since we assume they are equal.
    let schema = getSchemaSelectStmt select0

    return $ TileNode True
                      emptySelectStmt
                      { Q.selectClause =
                            columnsFromSchema alias schema
                      , Q.fromClause =
                            [ Q.FPAlias ( Q.FESubQuery
                                          $ Q.VQBinarySetOperation
                                            (Q.VQSelect select0)
                                            (Q.VQSelect select1)
                                            setOp
                                        )
                                        alias
                                        $ Just schema
                            ]
                      }
                      $ children0 ++ children1

-- | Perform a cross join between two nodes.
transformBinCrossJoin :: C.AlgNode
                      -> C.AlgNode
                      -> TransformMonad TileTree
transformBinCrossJoin c0 c1 = do
    (select0, children0) <- transformAsSelect c0
    (select1, children1) <- transformAsSelect c1

    -- We can simply concatenate everything, because all things are prefixed and
    -- cross join is associative.
    return $ TileNode True
                      -- Mergeable tiles are guaranteed to have at most a
                      -- select, from and where clause. (And since
                      -- 'selectFromTile' does this, we always get at most that
                      -- structure.)
                      emptySelectStmt
                      { Q.selectClause =
                            Q.selectClause select0 ++ Q.selectClause select1
                      , Q.fromClause =
                            Q.fromClause select0 ++ Q.fromClause select1
                      , Q.whereClause =
                            mergeWhereClause (Q.whereClause select0)
                                             $ Q.whereClause select1
                      }
                      -- Removing duplicates is not efficient here (since it
                      -- needs substitution on non-self joins).
                      -- Will be done automatically later on.
                      $ children0 ++ children1

-- | Perform a corss join with two nodes and get a select statement from the
-- result.
transformCJToSelect :: C.AlgNode
                    -> C.AlgNode
                    -> TransformMonad (Q.SelectStmt, TileChildren)
transformCJToSelect c0 c1 = do
    cTile <- transformBinCrossJoin c0 c1
    selectFromTile cTile

transformBinOp :: A.BinOp
               -> C.AlgNode
               -> C.AlgNode
               -> TransformMonad TileTree
transformBinOp (A.Cross ()) c0 c1 = transformBinCrossJoin c0 c1

transformBinOp (A.EqJoin (lName, rName)) c0 c1 = do

    (select, children) <- transformCJToSelect c0 c1

    let sClause = Q.selectClause select
        cond    = mkEqual (inlineColumn sClause lName)
                          $ inlineColumn sClause rName

    return $ TileNode True (appendToWhere cond select) children


transformBinOp (A.ThetaJoin conditions) c0 c1  = do

    (select, children) <- transformCJToSelect c0 c1

    -- Is there at least one join conditon?
    if null conditions
    then return $ TileNode True select children
    else do

        let sClause = Q.selectClause select
            cond    = foldr mkAnd (head conds) (tail conds)
            conds   = map f conditions
            f       = translateInlinedJoinCond sClause sClause

        return $ TileNode True (appendToWhere cond select) children

transformBinOp (A.SemiJoin cs) c0 c1          =
    transformExistsJoin cs c0 c1 id
transformBinOp (A.AntiJoin cs) c0 c1          =
    transformExistsJoin cs c0 c1 Q.VENot
transformBinOp (A.DisjUnion ()) c0 c1         =
    transformBinSetOp Q.SOUnionAll c0 c1
transformBinOp (A.Difference ()) c0 c1        =
    transformBinSetOp Q.SOExceptAll c0 c1

transformExistsJoin :: A.SemInfJoin
                    -> C.AlgNode 
                    -> C.AlgNode
                    -> (Q.ValueExpr -> Q.ValueExpr)
                    -> TransformMonad TileTree
transformExistsJoin conditions c0 c1 existsWrapF = case result of
    (Nothing, _)      -> do
        tile0 <- transformNode c0

        if null conditions
        then return tile0
        else do
            (select0, children0) <- selectFromTile tile0
            (select1, children1) <- transformAsSelect c1

            let outerCond   = existsWrapF . Q.VEExists $ Q.VQSelect innerSelect
                innerSelect = foldr appendToWhere select1 innerConds
                innerConds  = map f conditions
                f           = translateInlinedJoinCond (Q.selectClause select0)
                                                    $ Q.selectClause select1

            return $ TileNode True
                            (appendToWhere outerCond select0)
                            $ children0 ++ children1
    (Just (l, r), cs) -> do
        (select0, children0) <- transformAsSelect c0
        (select1, children1) <- transformAsSelect c1
       
        let -- Embedd the right query into the where clause of the left one.
            leftCond    = existsWrapF $ Q.VEIn (inlineColumn lSClause l)
                                        $ Q.VQSelect rightSelect
            -- Embedd all conditions in the right select, and set select clause
            -- to the right part of the equal join condition.
            rightSelect = (foldr f select1 cs) { Q.selectClause = [rightSCol] }
            f           = appendToWhere . translateInlinedJoinCond lSClause rSClause
            rightSCol   = Q.SCAlias (Q.SEValueExpr $ inlineColumn rSClause r) r
            lSClause    = Q.selectClause select0
            rSClause    = Q.selectClause select1

        return $ TileNode True
                          (appendToWhere leftCond select0)
                          $ children0 ++ children1
  where
    result                                = foldr tryIn (Nothing, []) conditions
    -- Tries to extract a join condition for usage in the IN sql construct.
    tryIn c (Just eqCols, r)              = (Just eqCols, c:r)
    tryIn c@(left, right, j) (Nothing, r) = case j of
        A.EqJ -> (Just (left, right), r)
        _     -> (Nothing, c:r)

-- | Combines transformation and convertion into 'SelectStmt'.
transformAsSelect :: C.AlgNode
                  -> TransformMonad (Q.SelectStmt, TileChildren) 
transformAsSelect n = do
    tile <- transformNode n
    selectFromTile tile

-- | Converts a 'TileTree' into a select statement, inlines if possible.
-- Select statements produced by this function are mergeable, which means they
-- contain at most a select, from and where clause and have distinct set to
-- tile.
selectFromTile :: TileTree
               -- The resulting 'SelectStmt' and used children (if the
               -- 'TileTree' could not be inlined or had children itself).
               -> TransformMonad (Q.SelectStmt, TileChildren)
selectFromTile t = case t of
    -- The only thing we are able to merge.
    TileNode True body children  -> return (body, children)
    -- Embed as sub query.
    TileNode False body children -> do
        alias <- generateAliasName

        let schema = getSchemaSelectStmt body

        return ( emptySelectStmt
                 { Q.selectClause =
                       columnsFromSchema alias schema
                 , Q.fromClause =
                       [mkSubQuery body alias $ Just schema]
                 }
               , children
               )
    -- Asign name and produce a 'SelectStmt' which uses it. (Let the
    -- materialization strategy handle it.)
    ReferenceLeaf _ s            -> do
        alias <- generateAliasName
        varId <- generateVariableId

        return ( emptySelectStmt
                   -- Use the schema to construct the select clause.
                 { Q.selectClause =
                       columnsFromSchema alias s
                 , Q.fromClause =
                       [mkFromPartVar varId alias $ Just s]
                 }
               , [(varId, t)]
               )
        -- Converts a column name into a select clause entry.

-- | Get the column names from a list of column names.
columnsFromSchema :: String -> [String] -> [Q.SelectColumn]
columnsFromSchema p = map (asSelectColumn p)

-- | Creates an alias which points at a prefixed column with the same name.
asSelectColumn :: String
               -> String
               -> Q.SelectColumn
asSelectColumn prefix columnName =
    Q.SCAlias (Q.SEValueExpr $ mkPCol prefix columnName) columnName

translateInlinedJoinCond :: [Q.SelectColumn] -- ^ Left select clause.
                         -> [Q.SelectColumn] -- ^ Right select clause.
                         -> (A.LeftAttrName, A.RightAttrName, A.JoinRel)
                         -> Q.ValueExpr
translateInlinedJoinCond lSClause rSClause j =
    translateJoinCond j (inlineColumn lSClause) (inlineColumn rSClause)


-- | Translate a 'A.SortInf' with inlining of value expressions.
translateInlinedSortInf :: [Q.SelectColumn]
                        -> A.SortInf
                        -> [Q.OrderExpr]
translateInlinedSortInf sClause si = translateSortInf si (inlineColumn sClause)

-- | Uses the select clause to try to inline an aliased value. 
inlineColumn :: [Q.SelectColumn]
             -> String
             -> Q.ValueExpr
inlineColumn selectClause attrName =
    fromMaybe (mkCol attrName) $ extractFromAlias attrName selectClause

-- | Tries to get a value expression from within a 'SCAlias'.
extractFromAlias :: String
                 -> [Q.SelectColumn]
                 -> Maybe Q.ValueExpr
extractFromAlias alias =
    -- Fold the list from left to right because we normally add columns from the
    -- left.
    foldr f Nothing
  where f (Q.SCAlias (Q.SEValueExpr e) a) r = if alias == a then return e
                                                            else r
        f _                               r = r

-- | Shorthand to make a prefixed column value expression.
mkPCol :: String
       -> String
       -> Q.ValueExpr
mkPCol p c = Q.VEColumn c $ Just p

-- | Shorthand to make an unprefixed column value expression.
mkCol :: String
      -> Q.ValueExpr
mkCol c = Q.VEColumn c Nothing

-- | Shorthand to apply the equal function to value expressions.
mkEqual :: Q.ValueExpr
        -> Q.ValueExpr
        -> Q.ValueExpr
mkEqual = Q.VEBinApp Q.BFEqual

mkAnd :: Q.ValueExpr
      -> Q.ValueExpr
      -> Q.ValueExpr
mkAnd = Q.VEBinApp Q.BFAnd

mergeWhereClause :: Maybe Q.ValueExpr -> Maybe Q.ValueExpr -> Maybe Q.ValueExpr
mergeWhereClause a b = case a of
    Nothing -> b
    Just e0 -> case b of
        Nothing -> a
        Just e1 -> Just $ mkAnd e0 e1

appendToWhere :: Q.ValueExpr        -- ^ The expression added with logical and.
              -> Q.SelectStmt       -- ^ The select statement to add to.
              -> Q.SelectStmt       -- ^ The result.
appendToWhere cond select = select
                            { Q.whereClause =
                                  case Q.whereClause select of
                                      Nothing -> Just cond
                                      Just e  -> Just $ mkAnd cond e
                            }

-- | Embeds a query into a from part as sub query.
mkSubQuery :: Q.SelectStmt
           -> String
           -> Maybe [String]
           -> Q.FromPart
mkSubQuery sel = Q.FPAlias (Q.FESubQuery $ Q.VQSelect sel)

mkFromPartVar :: Int
              -> String
              -> Maybe [String]
              -> Q.FromPart
mkFromPartVar identifier = Q.FPAlias (Q.FEVariable identifier)

-- | Generate a table reference which can be used within a from clause.
mkFromPartRef :: String          -- ^ The name of the table.
              -> Maybe [String]  -- ^ The optional columns.
              -> Q.FromPart
mkFromPartRef name = Q.FPAlias (Q.FETableReference name) name

-- | Translate 'A.JoinRel' into 'Q.BinaryFunction'.
translateJoinRel :: A.JoinRel
                 -> Q.BinaryFunction
translateJoinRel rel = case rel of
    A.EqJ -> Q.BFEqual
    A.GtJ -> Q.BFGreaterThan
    A.GeJ -> Q.BFGreaterEqual
    A.LtJ -> Q.BFLowerThan
    A.LeJ -> Q.BFLowerEqual
    A.NeJ -> Q.BFNotEqual

translateAggrType :: A.AggrType
                  -> (Q.AggregateFunction, Maybe A.Expr)
translateAggrType aggr = case aggr of
    A.Avg e  -> (Q.AFAvg, Just e)
    A.Max e  -> (Q.AFMax, Just e)
    A.Min e  -> (Q.AFMin, Just e)
    A.Sum e  -> (Q.AFSum, Just e)
    A.Count  -> (Q.AFCount, Nothing)
    A.All e  -> (Q.AFAll, Just e)
    A.Prod e -> (Q.AFProd, Just e)
    A.Dist e -> (Q.AFProd, Just e)

translateExpr :: Maybe [Q.SelectColumn] -> A.Expr -> Q.ValueExpr
translateExpr optSelectClause expr = case expr of
    A.BinAppE f e1 e2 ->
        Q.VEBinApp (translateBinFun f)
                   (translateExpr optSelectClause e1)
                   $ translateExpr optSelectClause e2
    A.UnAppE f e      ->
        case f of
            A.Not    -> Q.VENot tE
            A.Cast t -> Q.VECast tE $ translateATy t
      where tE = translateExpr optSelectClause e
    A.ColE n          -> case optSelectClause of
        Just s  -> inlineColumn s n
        Nothing -> mkCol n
    A.ConstE v        -> Q.VEValue $ translateAVal v

translateBinFun :: A.BinFun -> Q.BinaryFunction
translateBinFun f = case f of
    A.Gt        -> Q.BFGreaterThan
    A.Lt        -> Q.BFLowerThan
    A.GtE       -> Q.BFGreaterEqual
    A.LtE       -> Q.BFLowerEqual
    A.Eq        -> Q.BFEqual
    A.And       -> Q.BFAnd
    A.Or        -> Q.BFOr
    A.Plus      -> Q.BFPlus
    A.Minus     -> Q.BFMinus
    A.Times     -> Q.BFTimes
    A.Div       -> Q.BFDiv
    A.Modulo    -> Q.BFModulo
    A.Contains  -> Q.BFContains
    A.SimilarTo -> Q.BFSimilarTo
    A.Like      -> Q.BFLike
    A.Concat    -> Q.BFConcat

-- | Translate sort information into '[Q.OrderExpr]', using the column
-- function, which takes a 'String'.
translateSortInf :: A.SortInf
                 -> (String -> Q.ValueExpr)
                 -> [Q.OrderExpr]
translateSortInf si colFun = map f si
    where f (n, d) = Q.OE (colFun n) $ translateSortDir d


-- | Translate a single join condition into it's 'Q.ValueExpr' equivalent.
translateJoinCond :: (A.LeftAttrName, A.RightAttrName, A.JoinRel)
                  -> (String -> Q.ValueExpr) -- ^ Left column function.
                  -> (String -> Q.ValueExpr) -- ^ Right column function.
                  -> Q.ValueExpr
translateJoinCond (l, r, j) lColFun rColFun =
    Q.VEBinApp (translateJoinRel j) (lColFun l) (rColFun r)

translateSortDir :: A.SortDir -> Q.SortDirection
translateSortDir d = case d of
    A.Asc  -> Q.Ascending
    A.Desc -> Q.Descending

translateAVal :: A.AVal -> Q.Value
translateAVal v = case v of
    A.VInt i    -> Q.VInteger i
    A.VStr s    -> Q.VCharVarying s 
    A.VBool b   -> Q.VBoolean b
    A.VDouble d -> Q.VDoublePrecision d
    A.VDec d    -> Q.VDecimal d
    A.VNat n    -> Q.VInteger n

translateATy :: A.ATy -> Q.DataType
translateATy t = case t of
    A.AInt    -> Q.DTInteger
    A.AStr    -> Q.DTCharVarying
    A.ABool   -> Q.DTBoolean
    A.ADec    -> Q.DTDecimal
    A.ADouble -> Q.DTDoublePrecision
    A.ANat    -> Q.DTInteger

-- | Helper value to construct select statements.
emptySelectStmt :: Q.SelectStmt
emptySelectStmt = Q.SelectStmt [] False [] Nothing [] []

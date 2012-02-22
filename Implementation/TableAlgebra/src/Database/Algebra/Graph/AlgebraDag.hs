module Database.Algebra.Graph.AlgebraDag(AlgebraDag,
                                         mkDag,
                                         replaceRoot,
                                         nodeMap,
                                         Operator,
                                         opChildren,
                                         replaceOpChild,
                                         nodes,
                                         insert,
                                         replace,
                                         delete,
                                         parents,
                                         replaceChild,
                                         topsort,
                                         reachable,
                                         pruneUnused,
                                         mapd,
                                         operator,
                                         RewriteState,
                                         dag,
                                         -- FIXME remove export after debugging
                                         graph,
                                         rootNodes,
                                         DagRewrite,
                                         runDagRewrite,
                                         initRewriteState,
                                         insertM,
                                         replaceM,
                                         deleteM,
                                         parentsM,
                                         replaceChildM,
                                         topsortM,
                                         operatorM,
                                         inferM,
                                         pruneUnusedM,
                                         freshIDM,
                                         dagM,
                                         replaceRootM)
       where

import Database.Algebra.Graph.Common 

import qualified Data.Graph.Inductive.Graph as G
import qualified Data.Graph.Inductive.Query.DFS as DFS
import Data.Graph.Inductive.PatriciaTree

import qualified Data.Map as M
import qualified Data.Set as S

import Control.Monad.State

data AlgebraDag a = AlgebraDag {
    nodeMap :: NodeMap a,
    graph :: UGr,
    rootNodes :: [AlgNode]
}

class Operator a where
    opChildren :: a -> [AlgNode]
    replaceOpChild :: a -> AlgNode -> AlgNode -> a

mkDag :: Operator a => NodeMap a -> [AlgNode] -> AlgebraDag a
mkDag m rs = AlgebraDag { nodeMap = m, graph = g, rootNodes = rs }
    where g = uncurry G.mkUGraph $ M.foldrWithKey aux ([], []) m
          aux n op (allNodes, allEdges) = (n : allNodes, es ++ allEdges)
              where es = map (\v -> (n, v)) $ opChildren op
          
-- FIXME: assert that the new rootNode is known
replaceRoot :: AlgebraDag a -> AlgNode -> AlgNode -> AlgebraDag a
replaceRoot d old new = d { rootNodes = rs' }
  where rs' = map doReplace $ rootNodes d
        doReplace r = if r == old then new else old
          
nodes :: AlgebraDag a -> [AlgNode]
nodes = M.keys . nodeMap

insert :: Operator a => AlgNode -> a -> AlgebraDag a -> AlgebraDag a
insert n op d = 
    let cs = opChildren op
        g' = G.insEdges (map (\c -> (n, c, ())) cs) $ G.insNode (n, ()) $ graph d
        m' = M.insert n op $ nodeMap d
    in d { nodeMap = m', graph = g' }

-- | Replace the operator at a node with a new operator and keep the child edges intact.
replace :: Operator a => AlgNode -> a -> AlgebraDag a -> AlgebraDag a
replace n op d = 
    let newChildren = opChildren op
        oldChildren = opChildren $ operator n d
        g = graph d
        g' = G.delEdges (map (\c -> (n, c)) oldChildren) g
        g'' = G.insEdges (map (\c -> (n, c, ())) newChildren) g'
        m' = M.insert n op $ nodeMap d
    in d { nodeMap = m', graph = g'' }

delete :: Operator a => AlgNode -> AlgebraDag a -> AlgebraDag a
delete n d =
    let g' = G.delNode n $ graph d
        m' = M.delete n $ nodeMap d
    in d { nodeMap = m', graph = g' }

parents :: AlgNode -> AlgebraDag a -> [AlgNode]
parents n d = G.pre (graph d) n

replaceChild :: Operator a => AlgNode -> AlgNode -> AlgNode -> AlgebraDag a -> AlgebraDag a
replaceChild n old new d = 
    let m' = M.insert n (replaceOpChild (operator n d) old new) $ nodeMap d
        g' = G.insEdge (n, new, ()) $ G.delEdge (n, old) $ graph d
    in d { nodeMap = m', graph = g' }
{-
replaceChild n old new d = replace n (replaceOpChild (operator n d) old new) d
-}

topsort :: Operator a => AlgebraDag a -> [AlgNode]
topsort d = DFS.topsort $ graph d

operator :: AlgNode -> AlgebraDag a -> a
operator n d = 
    case M.lookup n $ nodeMap d of
        Just op -> op
        Nothing -> error $ "AlgebraDag.operator: lookup failed for " ++ (show n)
    
reachable :: AlgNode -> AlgebraDag a -> [AlgNode]
reachable n d = DFS.reachable n $ graph d
                
mapd :: (a -> b) -> AlgebraDag a -> AlgebraDag b
mapd f d = d { nodeMap = M.map f $ nodeMap d, graph = graph d }

data Cache = Cache {
    topOrdering :: [AlgNode]
    }

data RewriteState a = RewriteState {
    nodeIDSupply :: AlgNode,
    -- FIXME hack to supply fresh ids to X100.Render.Sharing
    -- they should implement their own supply
    supply :: Int,
    dag :: AlgebraDag a,
    cache :: Maybe Cache
    }

inferM :: (AlgebraDag a -> b) -> State (RewriteState a) b
inferM f =
    do
        d <- gets dag
        return $ f d

-- FIXME Map.findMax might call error
initRewriteState :: AlgebraDag a -> RewriteState a
initRewriteState d =
    let maxID = fst $ M.findMax $ nodeMap d
    in RewriteState { nodeIDSupply = maxID + 1, dag = d, cache = Nothing, supply = 0 }

freshNodeID :: DagRewrite a AlgNode
freshNodeID =
    do
        s <- get
        let n = nodeIDSupply s
        put $ s { nodeIDSupply = n + 1 }
        return n
    
freshIDM :: DagRewrite a Int
freshIDM =
    do
        s <- get
        let n = supply s
        put $ s { supply = n + 1 }
        return n

type DagRewrite a = State (RewriteState a)

runDagRewrite :: DagRewrite a b -> RewriteState a -> (b, RewriteState a)
runDagRewrite = runState

insertM :: Operator a => a -> DagRewrite a AlgNode
insertM op = 
    do
        n <- freshNodeID
        s <- get
        put $ s { dag = insert n op $ dag s, cache = Nothing }
        return n

-- | Replace the operator at a node with a new operator and keep the child edges intact.
replaceM :: Operator a => AlgNode -> a -> DagRewrite a ()
replaceM n op = 
    do
        s <- get
        put $ s { dag = replace n op $ dag s, cache = Nothing }

deleteM :: Operator a => AlgNode -> DagRewrite a ()
deleteM n = 
    do
        s <- get
        put $ s { dag = delete n $ dag s, cache = Nothing }

parentsM :: AlgNode -> DagRewrite a [AlgNode]
parentsM n = 
    do
        d <- gets dag
        return $ parents n d

-- | replaceChildM n old new replaces all links from node n to node old with links
--   to node new.
replaceChildM :: Operator a => AlgNode -> AlgNode -> AlgNode -> DagRewrite a ()
replaceChildM n old new = 
    do
        s <- get
        put $ s { dag = replaceChild n old new $ dag s, cache = Nothing }

topsortM :: Operator a => DagRewrite a [AlgNode]
topsortM = 
    do
        s <- get
        case cache s of
            Just c -> return $ topOrdering c
            Nothing -> do
                let d = dag s
                    ordering = topsort d
                put $ s { cache = Just $ Cache { topOrdering = ordering } }
                return ordering

operatorM :: AlgNode -> DagRewrite a a
operatorM n = 
    do
        d <- gets dag
        return $ operator n d
    
pruneUnused :: AlgebraDag a -> AlgebraDag a
pruneUnused d =
    let g = graph d
        m = nodeMap d 
        roots = rootNodes d
        allNodes = S.fromList $ G.nodes g
        reachableNodes = S.fromList $ concat $ map (flip DFS.reachable g) roots
        unreachableNodes = S.difference allNodes reachableNodes
        g' = G.delNodes (S.toList $ unreachableNodes) g
        m' = foldr M.delete m $ S.toList unreachableNodes
    in d { nodeMap = m', graph = g' }

pruneUnusedM :: DagRewrite a ()
pruneUnusedM =
    do
        s <- get
        put $ s { dag = pruneUnused $ dag s , cache = Nothing }
    
dagM :: DagRewrite a (AlgebraDag a)
dagM = 
    do
        s <- get
        return $ dag s
    
replaceRootM :: AlgNode -> AlgNode -> DagRewrite a ()
replaceRootM old new = do
  s <- get
  let d' = replaceRoot (dag s) old new
  put $ s { dag = d' }
  

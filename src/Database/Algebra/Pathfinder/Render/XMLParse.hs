
-- TODO migrate with XML ?
--module Database.Algebra.Pathfinder.Render.XMLParse
--    ( main
--    , queryNodeAttributes
--    , deserializeRowNum
--    ) where

import Control.Monad (guard, liftM2)
import Data.Function (on)
import Data.List (sortBy, transpose)
import Data.IntMap (fromList)
import Data.Maybe (listToMaybe, mapMaybe, catMaybes)
import System.Environment (getArgs)
import System.Exit (exitWith, ExitCode(ExitSuccess, ExitFailure))

import Text.XML.HaXml.Parse (xmlParse)
import Text.XML.HaXml.Posn (noPos, Posn)
import Text.XML.HaXml.Types ( Element (Elem)
                            , Document (Document)
                            , Content (CElem, CString)
                            , QName (N)
                            , AttValue (AttValue)
                            )
import Text.XML.HaXml.Namespaces (localName) -- we don't use xml namespaces
import Text.XML.HaXml.Combinators ( CFilter
                                  , (/>)
                                  , attr
                                  , attrval
                                  , children
                                  , childrenBy
                                  , path
                                  , tag
                                  , txt
                                  , with
                                  , without
                                  )
import Text.XML.HaXml.Verbatim (verbatim)

import Database.Algebra.Dag (mkDag, AlgebraDag)
import Database.Algebra.Dag.Common (AlgNode, Algebra(NullaryOp, UnOp, BinOp))
import Database.Algebra.Pathfinder.Data.Algebra



-- TODO:
-- handle escaped sequences and xml entities? how does verbatim work here?
-- convert comments into haddock format
-- fix top level node deserializer function comments
-- make comments more precise about what is meant by 'node'
-- handle deserialization of query_plan_bundle / query_plan / logical_query_plan
-- import Database.Algebra.Pathfinder.Data.Algebra qualified

main :: IO ()
main = do
    args <- getArgs
    case args of
        [filename] -> do
            content <- readFile filename
            
            -- used for debugging purposes
            mapM_ putStrLn $ parse filename content
            
            --putStr content
            exitWith $ ExitSuccess
        _          -> do
            putStrLn "missing filename"
            exitWith $ ExitFailure 1

testParse :: IO (Content Posn)
testParse = do
    str <- readFile "../xml_plans/test.xml"
    let (Document _ _ root _) = xmlParse "" str
    return (CElem root noPos)

parse :: String -> String -> [String]
parse filename content =
    map show $ sortBy compare $ map fst $ catMaybes $ generateNodes $ nodes
  where (Document _ _ root _) = xmlParse filename content
        nodes                 = tag "query_plan_bundle" /> tag "query_plan"
                                /> tag "logical_query_plan"
                                /> tag "node" $ CElem root noPos

-- generate a list of nodes from a list of xml elements FIXME remove
generateNodes :: [Content i] -> [Maybe (AlgNode, PFAlgebra)]
-- TODO maybe use sequence here
generateNodes es = map deserializeNode es

-- FIXME ugly solution for testing purposes
deserializeQueryPlan :: String -> String -> AlgebraDag PFAlgebra
deserializeQueryPlan filename content =
    -- FIXME not safe
    mkDag (fromList tuples) [foldl min (head nodeIds) (tail nodeIds)]

  where (Document _ _ root _) = xmlParse filename content
        nodes                 = tag "query_plan_bundle" /> tag "query_plan"
                                /> tag "logical_query_plan"
                                /> tag "node" $ CElem root noPos
        tuples                = mapMaybe deserializeNode nodes
        (nodeIds, _)          = unzip tuples

-- generate a node from an xml element
deserializeNode :: Content i -> Maybe (AlgNode, PFAlgebra)
deserializeNode node@(CElem (Elem _ attributes contents) _) = do

    identifier <- lookupConvert readMaybe "id" attributes
    kind <- lookupVerbatim "kind" attributes

    result <- case kind of
        -- nullary operators
        "empty_tbl"  -> deserializeEmptyTable node
        "table"      -> deserializeLitTable node
        "ref_tbl"    -> deserializeTableRef node
        
        -- unary operators
        "rownum"     -> deserializeRowNum node
        "rowrank"    -> deserializeRankOperator node RowRank
        "rank"       -> deserializeRankOperator node Rank
        "project"    -> deserializeProj node
        "select"     -> deserializeSel node
        "pos_sel"    -> deserializePosSel node
        "distinct"   -> deserializeDistinct node
        "attach"     -> deserializeAttach node
        "fun"        -> deserializeBinOpFun node
        
        -- unary operators with RelFun
        "gt"         -> deserializeBinOpRelFun node Gt
        "lt"         -> deserializeBinOpRelFun node Lt
        "eq"         -> deserializeBinOpRelFun node Eq
        "and"        -> deserializeBinOpRelFun node And
        "or"         -> deserializeBinOpRelFun node Or
        
        -- unary operators continued
        "cast"       -> deserializeCast node
        "not"        -> deserializeFunBoolNot node
        "aggr"       -> deserializeAggr node
        "dummy"      -> deserializeDummy node
        
        -- binary operators
        "cross"      -> deserializeCross node
        "eqjoin"     -> deserializeEqJoin node
        "thetajoin"  -> deserializeThetaJoin node
        "union"      -> deserializeDisjUnion node
        "difference" -> deserializeDifference node

        _  -> Nothing

    return (identifier, result)

generateNode _ = Nothing

-- TODO Maybe a solution with multiple calls and zip is better.
-- | Queries multiple attributes from a given node.
queryNodeAttributes :: [String] -> Content i -> Maybe [String]
queryNodeAttributes attList (CElem (Elem _ attributes _) _) =
    mapM (\att -> lookupVerbatim att attributes)
         attList

queryNodeAttributes _ _ = Nothing

-- | Queries all given attributes of the given node
-- and concatenates the text node's content in front.
queryNodeAttributesWithText :: [String] -> Content i -> Maybe [String]
queryNodeAttributesWithText attList c = do
    queriedAttributes <- queryNodeAttributes attList c
    text <- queryTextChild c
    return $ text : queriedAttributes

-- | Queries the text content of a given node.
queryTextChild :: Content i -> Maybe String
queryTextChild c = do
    (CString _ charData _) <- listToMaybe $ childrenBy txt c
    return charData
    
-- | Queries one attribute from a given node.
queryNodeAttribute :: String -> Content i -> Maybe String
queryNodeAttribute attName (CElem (Elem _ attributes _) _) =
    lookupVerbatim attName attributes

queryNodeAttribute _ _ = Nothing

-- | Assume the current node has only one child with the given tag name
-- and try to return it.
querySingletonChildByTag :: String -> Content i -> Maybe (Content i)
querySingletonChildByTag tagName = listToMaybe . (childrenBy $ tag tagName)

-- | Same as 'querySingletonChildByTag' but with a filter.
querySingletonChildByFilter :: CFilter i -> Content i -> Maybe (Content i)
querySingletonChildByFilter f  c = listToMaybe $ childrenBy f c

-- | Looks up an attribute and returns it as a 'String'.
lookupVerbatim :: String -> [(QName, AttValue)] -> Maybe String
lookupVerbatim = lookupConvert return

-- | Looks up an attribute and converts the result with the provided function.
lookupConvert :: (String -> Maybe a) -> String -> [(QName, AttValue)] -> Maybe a
lookupConvert fun name attributes = fun . verbatim =<< lookup (N name) attributes

-- | Tries to get the name of the result attribute from within a content node.
deserializeResultAttrName :: Content i -> Maybe String
deserializeResultAttrName contentNode = do
    -- <column name=... />
    ranNode <- listToMaybe $ childrenBy ranFilter contentNode
    queryNodeAttribute "name" ranNode
  where ranFilter = tag "column" `without` attr "function"

-- | Tries to get the partition attribute name from within a content node.
deserializePartAttrName :: Content i -> Maybe String
deserializePartAttrName contentNode = do
    columnNode <- listToMaybe $ childrenBy panFilter contentNode
    
    queryNodeAttribute "name" columnNode
  where panFilter = tag "column"
                    `with` attrval (N "function", AttValue $ [Left "partition"])

-- | Tries to get the sort information from the content node.
deserializeSortInf :: Content i -> Maybe SortInf
deserializeSortInf contentNode = do
    -- <column function="sort" position=... direction=... name=... />
    let sortInfoNodes = childrenBy siFilter contentNode
    
    queriedSortInfo <- mapM (queryNodeAttributes [ "position"
                                                 , "name"
                                                 , "direction"
                                                 ]
                            )
                            sortInfoNodes

    let tupleConv :: [String] -> Maybe (SortAttrName, SortDir)
        tupleConv [_, name, dirStr] = do
            direction <- deserializeSortDir dirStr
            return (name, direction)    
        tupleConv _                 = Nothing

    mapM tupleConv $ sortBy (on compare head) queriedSortInfo
  where siFilter  = tag "column"
                    `with` attrval (N "function", AttValue $ [Left "sort"])


-- | Try to get a single child id from the edge node's to attribute.
deserializeChildId1 :: Content i -> Maybe AlgNode
deserializeChildId1 node = do
    edgeNode <- querySingletonChildByTag "edge" node
    toEdge <- queryNodeAttribute "to" edgeNode
    readMaybe toEdge

-- | Try to get two child ids from the edge nodes' to attribute.
deserializeChildId2 :: Content i -> Maybe (AlgNode, AlgNode)
deserializeChildId2 node = case childIdList of 
        [edgeNode1, edgeNode2] -> liftM2 (,) edgeNode1 edgeNode2
        _                      -> Nothing
  where childIdList = map (\x -> readMaybe =<< queryNodeAttribute "to" x)
                          $ (childrenBy $ tag "edge") node

-- | Try to get the content child node of another node.
deserializeContentNode :: Content i -> Maybe (Content i)
deserializeContentNode node = querySingletonChildByTag "content" node

deserializeEmptyBinaryOpGeneric :: Content i -> (() -> BinOp) -> Maybe PFAlgebra
deserializeEmptyBinaryOpGeneric node constructor = do
    (childId1, childId2) <- deserializeChildId2 node
    return $ BinOp (constructor ()) childId1 childId2

deserializeCross :: Content i -> Maybe PFAlgebra
deserializeCross node = deserializeEmptyBinaryOpGeneric node Cross

deserializeEqJoin :: Content i -> Maybe PFAlgebra
deserializeEqJoin node = do
    (childId1, childId2) <- deserializeChildId2 node
    
    contentNode <- deserializeContentNode node
    
    infEqJoin <- deserializeBinOpPosArgs contentNode

    return $ BinOp (EqJoin infEqJoin) childId1 childId2


deserializeThetaJoin :: Content i -> Maybe PFAlgebra
deserializeThetaJoin node = do
    (childId1, childId2) <- deserializeChildId2 node
    
    contentNode <- deserializeContentNode node

    -- <comparison kind="$o">
    --    <column position="1" name="$leftAttrName">
    --    <column position="2" name="$rightAttrName">
    -- </comparison>
    
    infThetaJoin <- mapM deserializeComparison
                         $ (childrenBy $ tag "comparison") contentNode

    return $ BinOp (ThetaJoin infThetaJoin) childId1 childId2
  where deserializeComparison :: Content i
                              -> Maybe (LeftAttrName, RightAttrName, JoinRel)
        deserializeComparison compNode = do
            joinRelStr <- queryNodeAttribute "kind" compNode
            joinRel <- deserializeJoinRel joinRelStr
            
            (leftAttrName, rightAttrName) <- deserializeBinOpPosArgs compNode
            
            return (leftAttrName, rightAttrName, joinRel)
            
        deserializeJoinRel :: String -> Maybe JoinRel
        deserializeJoinRel s = case s of
            "eq" -> return EqJ
            "gt" -> return GtJ
            "ge" -> return GeJ
            "lt" -> return LtJ
            "le" -> return LeJ
            "ne" -> return NeJ
            _    -> Nothing


deserializeDisjUnion :: Content i -> Maybe PFAlgebra
deserializeDisjUnion node = deserializeEmptyBinaryOpGeneric node DisjUnion

deserializeDifference :: Content i -> Maybe PFAlgebra
deserializeDifference node = deserializeEmptyBinaryOpGeneric node Difference


deserializeDummy :: Content i -> Maybe PFAlgebra
deserializeDummy node = do
    childId <- deserializeChildId1 node
    
    contentNode <- deserializeContentNode node
    
    commentNode <- querySingletonChildByTag "comment" contentNode
    comment <- queryTextChild commentNode
    
    return $ UnOp (Dummy comment) childId

deserializeAggr :: Content i -> Maybe PFAlgebra
deserializeAggr node = do
    childId <- deserializeChildId1 node
    
    contentNode <- deserializeContentNode node
    
    -- parse aggregate nodes from contentNode
    -- read kind attribute from aggregate node
    -- depending on that, read
    --  - column function="item"
    
    aggrNodes <- mapM deserializeAggregate $ aggrFilter contentNode
    
    
    return $ UnOp ( Aggr ( aggrNodes
                         , deserializePartAttrName contentNode
                         )
                  )
                  childId
                  
  where aggrFilter = childrenBy $ tag "aggregate"
        deserializeAggregate :: Content i -> Maybe (AggrType, ResAttrName)
        deserializeAggregate aggregateNode = do
            aggregateStr <- queryNodeAttribute "kind" aggregateNode
            
            resAttrName <- deserializeNewColumnName aggregateNode
            
            aggregate <- case aggregateStr of
                "avg"      -> return . Avg =<< aC
                "max"      -> return . Max =<< aC
                "min"      -> return . Min =<< aC
                "sum"      -> return . Sum =<< aC
                "all"      -> return . All =<< aC
                "prod"     -> return . Prod =<< aC
                "distinct" -> return . Dist =<< aC
                "count"    -> return Count
                _          -> Nothing

            return (aggregate, resAttrName)

          -- has to be lazy
          where aC = deserializeOldColumnName aggregateNode

deserializeColumnNameWithNewValue :: Content i -> String -> Maybe ResAttrName
deserializeColumnNameWithNewValue contentNode newValue = do
    ranColumn <- querySingletonChildByFilter ranFilter contentNode
    queryNodeAttribute "name" ranColumn
  where ranFilter = tag "column"
                    `with` attrval (N "new", AttValue [Left newValue])

deserializeNewColumnName :: Content i -> Maybe ResAttrName
deserializeNewColumnName contentNode =
    deserializeColumnNameWithNewValue contentNode "true"

deserializeOldColumnName :: Content i -> Maybe AttrName
deserializeOldColumnName contentNode = do
    deserializeColumnNameWithNewValue contentNode "false"

deserializeFunBoolNot :: Content i -> Maybe PFAlgebra
deserializeFunBoolNot node = do
    childId <- deserializeChildId1 node
    
    contentNode <- deserializeContentNode node
    
    resAttrName <- deserializeNewColumnName contentNode

    attrName <- deserializeOldColumnName contentNode

    return $ UnOp (FunBoolNot (resAttrName, attrName))
                  childId

-- deserialize a cast operator
deserializeCast :: Content i -> Maybe PFAlgebra
deserializeCast node = do
    childId <- deserializeChildId1 node
    
    contentNode <- deserializeContentNode node
    
    resAttrName <- deserializeNewColumnName contentNode

    attrName <- deserializeOldColumnName contentNode

    typeNode <- querySingletonChildByTag "type" contentNode
    typeStr <- queryNodeAttribute "name" typeNode
    type_ <- deserializeATy typeStr
    
    return $ UnOp (Cast (resAttrName, attrName, type_))
                  childId

deserializeBinOpResAttrName :: Content i -> Maybe ResAttrName
deserializeBinOpResAttrName contentNode = do
    resNode <- querySingletonChildByFilter resColumnFilter contentNode
    queryNodeAttribute "name" resNode
  where resColumnFilter = tag "column" `without` attr "position"

-- deserialize positional arguments used by a BinOp
deserializeBinOpPosArgs :: Content i -> Maybe (LeftAttrName, RightAttrName)
deserializeBinOpPosArgs contentNode = do
    unsortedResult <- mapM (queryNodeAttributes ["position", "name"]) 
                           $ posColumnFilter contentNode

    case map (head . tail) $ sortBy (on compare head) unsortedResult of
        [lName, rName] -> return (lName, rName)
        _              -> Nothing
        
  where posColumnFilter = (childrenBy $ tag "column" `with` attr "position")

-- deserialize a binary operator with RelFun
deserializeBinOpRelFun :: Content i -> RelFun -> Maybe PFAlgebra
deserializeBinOpRelFun node relFun = do
    childId <- deserializeChildId1 node
    
    contentNode <- deserializeContentNode node

    resAttrName <- deserializeBinOpResAttrName contentNode

    (lName, rName) <- deserializeBinOpPosArgs contentNode

    return $ UnOp (FunBinOp ( RelFun relFun
                            , resAttrName
                            , lName
                            , rName
                            )
                  )
                  childId

deserializeRelFun :: String -> Maybe RelFun
deserializeRelFun s = case s of
    "gt"  -> return Gt
    "lt"  -> return Lt
    "eq"  -> return Eq
    "and" -> return And
    "or"  -> return Or
    _     -> Nothing
    
-- deserialize a binary operator with Fun1to1 as function
deserializeBinOpFun :: Content i -> Maybe PFAlgebra
deserializeBinOpFun node = do
    childId <- deserializeChildId1 node
    
    contentNode <- deserializeContentNode node
    
    kindNode <- querySingletonChildByFilter kindFilter contentNode
    funName <- queryNodeAttribute "name" kindNode
    fun <- deserializeFun1to1 funName

    resAttrName <- deserializeBinOpResAttrName contentNode

    (lName, rName) <- deserializeBinOpPosArgs contentNode

    return $ UnOp (FunBinOp ( Fun1to1 fun
                            , resAttrName
                            , lName
                            , rName
                            )
                  )
                  childId
  where kindFilter = (childrenBy $ tag "kind")

-- deserialize the ugly Fun1to1 results of show
deserializeFun1to1 :: String -> Maybe Fun1to1
deserializeFun1to1 s = case s of
    "add"           -> return Plus
    "subtract"      -> return Minus
    "multiplay"     -> return Times
    "divide"        -> return Div
    "modulo"        -> return Modulo
    "fn:contains"   -> return Contains
    "fn:similar_to" -> return SimilarTo
    "fn:concat"     -> return Concat
    _               -> Nothing

deserializeAttach :: Content i -> Maybe PFAlgebra
deserializeAttach node = do
    childId <- deserializeChildId1 node
    
    contentNode <- deserializeContentNode node
    
    columnNode <- querySingletonChildByTag "column" contentNode
    
    resAttrName <- queryNodeAttribute "name" columnNode
    
    valueNode <- querySingletonChildByTag "value" columnNode
    
    typeStr <- queryNodeAttribute "type" valueNode
    type_ <- deserializeATy typeStr
    
    valueStr <- queryTextChild valueNode
    value <- deserializeAVal type_ valueStr
    
    return $ UnOp (Attach (resAttrName, (type_, value))) childId

deserializeDistinct :: Content i -> Maybe PFAlgebra
deserializeDistinct node = do
    childId <- deserializeChildId1 node
    return $ UnOp (Distinct ()) childId

deserializePosSel :: Content i -> Maybe PFAlgebra
deserializePosSel node = do
    childId <- deserializeChildId1 node
    
    contentNode <- deserializeContentNode node
    
    sortInfo <- deserializeSortInf contentNode
    
    -- TODO really plain text?
    positionNode <- querySingletonChildByTag "position" contentNode
    positionText <- queryTextChild positionNode
    position <- readMaybe positionText
    
    return $ UnOp (PosSel ( position
                          , sortInfo
                          , deserializePartAttrName contentNode
                          )
                  )
                  childId

deserializeSel :: Content i -> Maybe PFAlgebra
deserializeSel node = do
    childId <- deserializeChildId1 node
    
    contentNode <- deserializeContentNode node
    
    columnNode <- querySingletonChildByTag "column" contentNode

    columnName <- queryNodeAttribute "name" columnNode

    return $ UnOp (Sel columnName) childId 

-- | Tries to deserialize into 'Proj'.
deserializeProj :: Content i -> Maybe PFAlgebra
deserializeProj node = do
    childId <- deserializeChildId1 node
    
    contentNode <- deserializeContentNode node
    
    -- FIXME what to do with columns with just the name attribute?
    projectionLists <- mapM (queryNodeAttributes ["name", "old_name"])
                            $ (childrenBy $ tag "column") contentNode
    
    projectionInf <- mapM tupleConv projectionLists
    
    return $ UnOp (Proj $ projectionInf) childId
  where tupleConv [x, y] = return (x, y)
        tupleConv _      = Nothing

-- | Tries to deserialize a row rank or rank operator. They use the same
-- deserialize function because the only difference is the data constructor
-- itself.
deserializeRankOperator :: Content i -> (SemInfRank -> UnOp) -> Maybe PFAlgebra
deserializeRankOperator node constructor = do
    childId <- deserializeChildId1 node

    -- <content> should be singleton
    contentNode <- deserializeContentNode node
    
    resAttrName <- deserializeResultAttrName contentNode
    
    sortInfo <- deserializeSortInf contentNode

    return $ UnOp (constructor ( resAttrName
                               , sortInfo
                               )
                  )
                  childId

-- | Tries to deserialize into a 'RowNum'.
deserializeRowNum :: Content i -> Maybe PFAlgebra
deserializeRowNum node = do

    childId <- deserializeChildId1 node

    -- <content> should be singleton
    contentNode <- deserializeContentNode node
    
    resAttrName <- deserializeResultAttrName contentNode

    -- TODO string comparison sufficient ?
    sortInfo <- deserializeSortInf contentNode
    
    return $ UnOp (RowNum ( resAttrName
                          , sortInfo
                          -- optional
                          , deserializePartAttrName contentNode
                          )
                  )
                  childId

-- | Tries to deserialize a 'LitTable'.
deserializeLitTable :: Content i -> Maybe PFAlgebra
deserializeLitTable node = do
    contentNode <- deserializeContentNode node

    let columnNodes = childrenBy (tag "column") contentNode

    results <- mapM deserializeLitTableColumn columnNodes

    -- FIXME pattern matching safe here?
    let tableContent = transpose $ map (\(_, _, vals) -> vals) results

    return $ NullaryOp $ LitTable tableContent
                                  $ map (\(n, t, _) -> (n, t))
                                        results

-- | Tries to deserialize a table column of a 'LitTable'.
deserializeLitTableColumn :: Content i -> Maybe (AttrName, ATy, [AVal])
deserializeLitTableColumn columnNode = do
    
    name <- queryNodeAttribute "name" columnNode

    -- FIXME is value a single child of column in xml?
    let valueNodes = childrenBy (tag "value") columnNode
    result <- mapM deserializeLitTableValue valueNodes
    
    type_ <- the $ map fst result
    
    return (name, type_, map snd result)

-- | Tries to deserialize a value node into a tuple of 'ATy' and 'AVal'.
deserializeLitTableValue :: Content i -> Maybe (ATy, AVal)
deserializeLitTableValue valueNode = do
    typeStr <- queryNodeAttribute "type" valueNode
    type_ <- deserializeATy typeStr
    
    valueStr <- queryTextChild valueNode
    value <- deserializeAVal type_ valueStr

    return (type_, value)

-- | Tries to deserialize a 'TableRef'.
deserializeTableRef :: Content i -> Maybe PFAlgebra
deserializeTableRef node = do
    propertiesNode <- querySingletonChildByTag "properties" node
    keyInfos <- deserializeTableRefProperties propertiesNode
    
    contentElement <- deserializeContentNode node
    (tableName, attrInfo) <- deserializeTableRefContent contentElement
    
    return $ NullaryOp $ TableRef (tableName, attrInfo, keyInfos)

-- | Tries to deserialize the properties node into 'KeyInfos'.
deserializeTableRefProperties :: Content i -> Maybe KeyInfos
deserializeTableRefProperties propertiesNode = do
    -- there should only be one
    keysNode <- querySingletonChildByTag "keys" propertiesNode
    
    -- <keys><key> .. </key> .. <keys>
    -- FIXME mapM too strict?
    keyInfos <- mapM deserializeKeyInfo
                     $ childrenBy (tag "key") keysNode
    
    return keyInfos

-- | Tries to deserializes a key node into 'KeyInfo'.
deserializeKeyInfo :: Content i -> Maybe KeyInfo
deserializeKeyInfo keyNode = do
    -- <key><column ..> .. </key>
    -- FIXME mapM to strict?
    keyInfos <- mapM deserializeKeyInfoColumn
                     $ (childrenBy $ tag "column") keyNode

    -- restore ordering (based on first tuple element) and map to second
    return $ map snd $ sortBy (on compare fst) keyInfos


-- | Tries to deserialize a column node below a key node into position and name.
deserializeKeyInfoColumn :: Content i -> Maybe (Int, AttrName)
deserializeKeyInfoColumn columnNode = do
    -- <column name=.. position=..>
    name <- queryNodeAttribute "name" columnNode
    positionStr <- queryNodeAttribute "position" columnNode
    position <- readMaybe positionStr

    return (position, name)

-- | Tries to deserialize the content node in a 'TableRef'.
deserializeTableRefContent :: Content i -> Maybe (TableName, TableAttrInf)
deserializeTableRefContent contentNode = do
    tableNode <- querySingletonChildByTag "table" contentNode
    name <- queryNodeAttribute "name" tableNode
    
    -- FIXME mapM to strict?
    attributeInfo <- mapM deserializeTableRefColumn
                          $ (childrenBy $ tag "column") tableNode
    
    return (name, attributeInfo)

-- | Tries to deserialize a column node belonging to a 'TableRef'.
deserializeTableRefColumn :: Content i -> Maybe (AttrName, AttrName, ATy)
deserializeTableRefColumn columnNode = do

    qAttr <- queryNodeAttributes ["name", "tname", "type"] columnNode

    case qAttr of
        [name, newName, typeStr] -> do
                                        type_ <- deserializeATy typeStr
                                        return (name, newName, type_)
        _                        -> Nothing

-- | Tries to deserialize an 'EmptyTable'.
deserializeEmptyTable :: Content i -> Maybe PFAlgebra
deserializeEmptyTable node = do

    contentNode <- deserializeContentNode node
    
    -- FIXME mapM to strict ?
    schema <- mapM deserializeEmptyTableColumn
                   $ (childrenBy $ tag "column") contentNode

    return $ NullaryOp $ EmptyTable schema

-- | Tries to deserialize a column node belonging to a 'EmptyTable' into
-- a tuple containing 'AttrName' and 'ATy'.
deserializeEmptyTableColumn :: Content i -> Maybe (AttrName, ATy)
deserializeEmptyTableColumn columnNode = do
    name <- queryNodeAttribute "name" columnNode
    typeStr <- queryNodeAttribute "type" columnNode
    type_ <- deserializeATy typeStr

    return (name, type_)
    

-- | Tries to deserialize a 'String' into 'Bool'.
deserializeBool :: String -> Maybe Bool
deserializeBool s = case s of
    "true"  -> return True
    "false" -> return False
    _       -> Nothing


-- | Tries to deserialize a 'String' into 'AVal'.
deserializeAVal :: ATy -> String -> Maybe AVal
deserializeAVal t s = case t of
    AInt    -> return . VInt =<< readMaybe s
    AStr    -> return . VStr =<< readMaybe s
    ABool   -> return . VBool =<< readMaybe s
    ADec    -> return . VDec =<< readMaybe s
    ADouble -> return . VDouble =<< readMaybe s
    ANat    -> return . VNat =<< readMaybe s
    -- FIXME not used because no value type available?
    ASur    -> Nothing


-- | Tries to deserialize a 'String' into 'ATy'.
deserializeATy :: String -> Maybe ATy
deserializeATy s = case s of
    "int"  -> return AInt
    "str"  -> return AStr
    "bool" -> return ABool
    "dec"  -> return ADec
    "dbl"  -> return ADouble
    "nat"  -> return ANat
    -- FIXME "nat" is also used for ASur, another mistake ?
    _      -> Nothing

-- | Tries to deserialize a 'String' into 'SortDir'.
deserializeSortDir :: String -> Maybe SortDir
deserializeSortDir s = case s of
    "ascending"  -> return Asc
    "descending" -> return Desc
    _            -> Nothing

-- FIXME may be defined in ghc 7.6 ?
-- | Wraps a call to reads into a 'Maybe'.
readMaybe :: Read a => String -> Maybe a
readMaybe s = case reads s of
    [(x, "")] -> return x
    _         -> Nothing

-- FIXME defined in GHC.Exts but without Maybe
-- | Checks whether every element of the list is the same and returns a 'Maybe'
-- with it.
the :: Eq a => [a] -> Maybe a
the []     = Nothing
the (x:xs) = helper x xs
  where helper y []     = return y
        helper y (z:zs) | (y == z)  = helper z zs
                        | otherwise = Nothing


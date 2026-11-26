{-# LANGUAGE OverloadedStrings #-}
-- | The statements which change tuples run on top of layers which exist only to make them fast: relation variables hold their tuples in a store which shares structure between versions, keys are answered by indexes, only the constraints which a statement can affect are checked again, and a commit writes the change instead of the database.
--
-- None of that may change what a statement means. This test runs a long pseudo-random (but fixed) sequence of statements against a database on disk and against a model which knows nothing of those layers: a plain set of rows, the textbook meaning of insert, update and delete, and constraints which are checked by looking at all rows. Database and model have to agree after every statement on the tuples and on whether the statement is rejected, and the database has to come back from disk in the state of the model.
import Test.HUnit
import ProjectM36.Client
import ProjectM36.Base (Attributes, Relation)
import ProjectM36.Relation (mkRelationFromList)
import ProjectM36.Attribute (attributesFromList)
import qualified Data.Map as M
import qualified Data.Set as S
import qualified Data.Text as T
import Data.Text (Text)
import Data.Either (isLeft, isRight)
import Control.Monad (foldM, when)
import System.Exit
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import System.Random (StdGen, mkStdGen, randomR, initStdGen)

main :: IO ()
main = do
  tcounts <- runTestTT (TestList [testStatementsAgreeWithModel])
  if errors tcounts + failures tcounts > 0 then exitFailure else exitSuccess

-- | A row of the relation variable @t {id Integer, grp Integer, val Text}@.
type Row = (Integer, Integer, Text)

-- | The rows of @t@ and the tuples of @g {grp Integer}@. @id@ is a key of @t@, and every @grp@ of @t@ has to be in @g@.
data Model = Model { rows :: S.Set Row, groups :: S.Set Integer }
  deriving (Eq, Show)

data Statement = InsertRows Bool [Row] -- ^ the flag chooses how the relation to insert is written
               | DeleteById Integer
               | DeleteByGroup Integer
               | DeleteOtherGroups Integer
               | UpdateVal Integer Text
               | UpdateGroup Integer Integer
               | UpdateId Integer Integer
               | InsertGroup Integer
               | DeleteGroup Integer
               | CommitNow
               | RollbackNow
               deriving Show

-- | What the statement makes of the model, whether or not the result is allowed.
applyToModel :: Statement -> Model -> Model
applyToModel stmt model =
  case stmt of
    InsertRows _ new -> model { rows = S.union (rows model) (S.fromList new) }
    DeleteById k -> model { rows = S.filter (\(i, _, _) -> i /= k) (rows model) }
    DeleteByGroup grp -> model { rows = S.filter (\(_, g, _) -> g /= grp) (rows model) }
    DeleteOtherGroups grp -> model { rows = S.filter (\(_, g, _) -> g == grp) (rows model) }
    UpdateVal k val -> model { rows = S.map (\row@(i, g, _) -> if i == k then (i, g, val) else row) (rows model) }
    UpdateGroup from to -> model { rows = S.map (\row@(i, g, v) -> if g == from then (i, to, v) else row) (rows model) }
    UpdateId from to -> model { rows = S.map (\row@(i, g, v) -> if i == from then (to, g, v) else row) (rows model) }
    InsertGroup grp -> model { groups = S.insert grp (groups model) }
    DeleteGroup grp -> model { groups = S.delete grp (groups model) }
    CommitNow -> model
    RollbackNow -> model

-- | The constraints, checked the slow and obvious way.
allowed :: Model -> Bool
allowed model = keyHolds && everyGroupExists
  where
    ids = map (\(i, _, _) -> i) (S.toList (rows model))
    keyHolds = S.size (S.fromList ids) == length ids
    everyGroupExists = all (\(_, g, _) -> S.member g (groups model)) (S.toList (rows model))

rowAttributes :: Attributes
rowAttributes = attributesFromList [Attribute "id" IntegerAtomType, Attribute "grp" IntegerAtomType, Attribute "val" TextAtomType]

groupAttributes :: Attributes
groupAttributes = attributesFromList [Attribute "grp" IntegerAtomType]

rowsRelation :: S.Set Row -> Either RelationalError Relation
rowsRelation rs = mkRelationFromList rowAttributes [[IntegerAtom i, IntegerAtom g, TextAtom v] | (i, g, v) <- S.toList rs]

groupsRelation :: S.Set Integer -> Either RelationalError Relation
groupsRelation gs = mkRelationFromList groupAttributes [[IntegerAtom g] | g <- S.toList gs]

-- | The statement for the database. Commit and rollback are not database context expressions.
statementExpr :: Statement -> Maybe DatabaseContextExpr
statementExpr stmt =
  case stmt of
    InsertRows asValue new -> Just (Insert "t" (if asValue then rowsValue new else rowsExpr new))
    DeleteById k -> Just (Delete "t" (idIs k))
    DeleteByGroup grp -> Just (Delete "t" (groupIs grp))
    DeleteOtherGroups grp -> Just (Delete "t" (NotPredicate (groupIs grp)))
    UpdateVal k val -> Just (Update "t" (M.singleton "val" (NakedAtomExpr (TextAtom val))) (idIs k))
    UpdateGroup from to -> Just (Update "t" (M.singleton "grp" (NakedAtomExpr (IntegerAtom to))) (groupIs from))
    UpdateId from to -> Just (Update "t" (M.singleton "id" (NakedAtomExpr (IntegerAtom to))) (idIs from))
    InsertGroup grp -> Just (Insert "g" (MakeRelationFromExprs Nothing (TupleExprs () [TupleExpr (M.singleton "grp" (NakedAtomExpr (IntegerAtom grp)))])))
    DeleteGroup grp -> Just (Delete "g" (groupIs grp))
    CommitNow -> Nothing
    RollbackNow -> Nothing
  where
    idIs k = AttributeEqualityPredicate "id" (NakedAtomExpr (IntegerAtom k))
    groupIs grp = AttributeEqualityPredicate "grp" (NakedAtomExpr (IntegerAtom grp))
    rowsExpr new = MakeRelationFromExprs Nothing (TupleExprs () [TupleExpr (M.fromList [("id", NakedAtomExpr (IntegerAtom i)),
                                                                                       ("grp", NakedAtomExpr (IntegerAtom g)),
                                                                                       ("val", NakedAtomExpr (TextAtom v))]) | (i, g, v) <- new])
    rowsValue new = either (error . show) ExistingRelation (rowsRelation (S.fromList new))

-- | Few ids, groups and values, so that statements collide: inserts hit existing keys and missing groups, updates and deletes find something to change.
genStatement :: StdGen -> (Statement, StdGen)
genStatement g0 = (stmt, g7)
  where
    (choice, g1) = randomR (0 :: Int, 99) g0
    (k, g2) = randomR (1, 25) g1
    (k2, g3) = randomR (1, 25) g2
    (grp, g4) = randomR (0, 5) g3
    (grp2, g5) = randomR (0, 5) g4
    (valNo, g6) = randomR (0 :: Int, 3) g5
    (asValue, g7) = randomR (False, True) g6
    val = T.pack ("v" <> show valNo)
    stmt | choice < 32 = InsertRows asValue [(k, grp, val)]
         | choice < 38 = InsertRows asValue [(k, grp, val), (k2, grp2, val)]
         | choice < 48 = DeleteById k
         | choice < 53 = DeleteByGroup grp
         | choice < 56 = DeleteOtherGroups grp
         | choice < 68 = UpdateVal k val
         | choice < 74 = UpdateGroup grp grp2
         | choice < 80 = UpdateId k k2
         | choice < 85 = InsertGroup grp
         | choice < 90 = DeleteGroup grp
         | choice < 97 = CommitNow
         | otherwise = RollbackNow

genStatements :: Int -> StdGen -> [Statement]
genStatements 0 _ = []
genStatements n gen = let (stmt, gen') = genStatement gen in stmt : genStatements (n - 1) gen'

testStatementsAgreeWithModel :: Test
testStatementsAgreeWithModel = TestCase $
  withSystemTempDirectory "m36testdb" $ \tempdir -> do
    rando <- initStdGen
    let dbdir = tempdir </> "db"
        connInfo = InProcessConnectionInfo (MinimalPersistence dbdir) emptyNotificationCallback [] basicDatabaseContext rando adminRoleName
        must :: Show e => String -> IO (Either e a) -> IO a
        must what action = action >>= either (\err -> assertFailure (what <> ": " <> show err) >> error what) pure
        initial = Model { rows = S.empty, groups = S.fromList [0 .. 3] }
        check sess conn n stmt model = do
          t <- executeRelationalExpr sess conn (RelationVariable "t" ())
          assertEqual ("t after statement " <> show n <> " " <> show stmt) (rowsRelation (rows model)) t
          g <- executeRelationalExpr sess conn (RelationVariable "g" ())
          assertEqual ("g after statement " <> show n <> " " <> show stmt) (groupsRelation (groups model)) g
    conn <- must "connect" (connectProjectM36 connInfo)
    sess <- must "session" (createSessionAtHead conn "master")
    mapM_ (must "setup" . executeDatabaseContextExpr sess conn)
      [Define "t" (map NakedAttributeExpr [Attribute "id" IntegerAtomType, Attribute "grp" IntegerAtomType, Attribute "val" TextAtomType]),
       Define "g" [NakedAttributeExpr (Attribute "grp" IntegerAtomType)],
       Insert "g" (either (error . show) ExistingRelation (groupsRelation (groups initial))),
       databaseContextExprForUniqueKey "t" ["id"],
       databaseContextExprForForeignKey "t_g_fk" ("t", ["grp"]) ("g", ["grp"])]
    must "commit" (commit sess conn)

    -- (the model as of the last commit, the current model, how many statements were rejected)
    let step (committed, model, rejected) (n, stmt) =
          case statementExpr stmt of
            Nothing -> do
              case stmt of
                RollbackNow -> do
                  must "rollback" (rollback sess conn)
                  check sess conn n stmt committed
                  pure (committed, committed, rejected)
                _ -> do
                  must "commit" (commit sess conn)
                  check sess conn n stmt model
                  pure (model, model, rejected)
            Just expr -> do
              let model' = applyToModel stmt model
              result <- executeDatabaseContextExpr sess conn expr
              if allowed model' then do
                assertBool ("statement " <> show n <> " " <> show stmt <> " must be accepted: " <> show result) (isRight result)
                check sess conn n stmt model'
                pure (committed, model', rejected)
                else do
                assertBool ("statement " <> show n <> " " <> show stmt <> " must be rejected") (isLeft result)
                check sess conn n stmt model
                pure (committed, model, rejected + 1 :: Int)
        statements = genStatements 600 (mkStdGen 20261126)
    (_, final, rejected) <- foldM step (initial, initial, 0) (zip [1 :: Int ..] statements)
    -- the sequence has to exercise both outcomes and end with something to look at
    assertBool ("rejected statements: " <> show rejected) (rejected > 30)
    assertBool ("rows at the end: " <> show (S.size (rows final))) (S.size (rows final) > 3)
    must "final commit" (commit sess conn)
    close conn

    -- what was committed is what comes back from disk
    conn' <- must "reconnect" (connectProjectM36 connInfo)
    sess' <- must "session" (createSessionAtHead conn' "master")
    check sess' conn' (0 :: Int) CommitNow final
    hashes <- validateMerkleHashes sess' conn'
    assertEqual "merkle hashes after reopening" (Right ()) hashes
    when (S.null (groups final)) (assertFailure "no groups left")
    close conn'

{-# LANGUAGE CPP #-}
import Test.HUnit
import ProjectM36.Base
import ProjectM36.Persist (DiskSync(NoDiskSync))
import ProjectM36.RelationalExpression (resolveDBC', transactionForId)
import ProjectM36.TransactionGraph.Persist
import ProjectM36.IsomorphicSchema.Types
import ProjectM36.Transaction.Types as T
import ProjectM36.TransactionGraph as TG
import ProjectM36.TransactionGraph.Types
import qualified ProjectM36.TransactionGraph.Index as TIdx
import ProjectM36.DatabaseContext
import ProjectM36.DisconnectedTransaction
import ProjectM36.DateExamples
import ProjectM36.ValueMarker
import System.IO.Temp
import System.Exit
import System.Directory
import Data.Either
import Data.UUID.V4 (nextRandom)
import System.FilePath
import TutorialD.Interpreter.DatabaseContextExpr
import qualified Data.Map as M
import qualified Data.Set as S
import Data.Time.Clock
import Data.Time.Calendar
import ProjectM36.Client as C
import ProjectM36.Relation
import ProjectM36.DatabaseContext.Types hiding (DatabaseContextFunctionUtils(..))
import qualified ProjectM36.DatabaseContext.Types as DBT
import Control.Monad (forM, forM_)
import qualified Data.Vector as V
import qualified Data.ByteString as BS
import ProjectM36.Attribute (attributesFromList)
import ProjectM36.Error
import System.Random

main :: IO ()           
main = do 
  tcounts <- runTestTT testList
  if errors tcounts + failures tcounts > 0 then exitFailure else exitSuccess
  
testList :: Test
testList = TestList [testBootstrapDB, 
                     testDBSimplePersistence,
                     testFunctionPersistence,
                     testMerkleHashValidation,
                     testTransactionDirectorySizeGrowth,
                     testIncrementalRelVarPersistence,
                     testStoredRelVarsAndReferences,
                     testInterruptedLogWrite
                     ]

stamp' :: UTCTime
stamp' = UTCTime (fromGregorian 1980 01 01) (secondsToDiffTime 1000)

{- bootstrap a database, ensure that it can be read -}
testBootstrapDB :: Test
testBootstrapDB = TestCase $ withSystemTempDirectory "m36testdb" $ \tempdir -> do
  let dbdir = tempdir </> "dbdir"
  freshId <- nextRandom

  _ <- bootstrapDatabaseDir NoDiskSync dbdir (bootstrapTransactionGraph stamp' freshId (toDatabaseContext dateExamples))
  loadedGraph <- transactionGraphLoad dbdir emptyTransactionGraph Nothing
  assertBool "transactionGraphLoad" $ isRight loadedGraph

{- create a database with several transactions, ensure that all transactions can be read -}
testDBSimplePersistence :: Test
testDBSimplePersistence = TestCase $ withSystemTempDirectory "m36testdb" $ \tempdir -> do
  let dbdir = tempdir </> "dbdir"
  freshId <- nextRandom

  let graph = bootstrapTransactionGraph stamp' freshId (toDatabaseContext dateExamples)
  _ <- bootstrapDatabaseDir NoDiskSync dbdir graph
  case transactionForHead "master" graph of
    Nothing -> assertFailure "Failed to retrieve head transaction for master branch."
    Just headTrans -> 
          case interpretDatabaseContextExpr (T.concreteDatabaseContext headTrans) (transactionId headTrans) graph "x:=s" of
            Left err -> assertFailure (show err)
            Right context' -> do
              freshId' <- nextRandom
              let newdiscon = DisconnectedTransaction (transactionId headTrans) (Schemas context' emptyValue) (CurrentHeadBranch "master")
                  addTrans = addDisconnectedTransaction stamp' freshId' newdiscon graph
              --add a transaction to the graph
              case addTrans of
                Left err -> assertFailure (show err)
                Right (_, graph') -> do
                  --persist the new graph
                  _ <- transactionGraphPersist NoDiskSync dbdir graph'
                  --reload the graph from the filesystem and confirm that the transaction is present
                  graphErr <- transactionGraphLoad dbdir emptyTransactionGraph Nothing
                  let mapEq graphArg = transactionIdsForGraph graphArg
                  case graphErr of
                    Left err -> assertFailure (show err)
                    Right graph'' -> assertBool "graph equality" (mapEq graph'' == mapEq graph')

testMerkleHashValidation :: Test
testMerkleHashValidation = TestCase $
  -- add a commit and validate the hashes successfully
  withSystemTempDirectory "m36testdb" $ \tempdir -> do
  rando <- initStdGen
  let dbdir = tempdir </> "dbdir"
      connInfo = InProcessConnectionInfo (MinimalPersistence dbdir) emptyNotificationCallback [] basicDatabaseContext rando adminRoleName
  conn <- assertIOEither $ connectProjectM36 connInfo
  sess <- assertIOEither $ createSessionAtHead conn "master"
  Right _ <- executeDatabaseContextExpr sess conn (Assign "x" (ExistingRelation relationTrue))
  -- add a notification because we forgot to read/write it as part of the transaction before
  let relX = RelationVariable "x" ()
  Right _ <- executeDatabaseContextExpr sess conn (AddNotification "testnotif" relX relX relX)
  Right _ <- commit sess conn
  val <- C.validateMerkleHashes sess conn
  assertEqual "merkle success" (Right ()) val

  --read graph from disk
  conn' <- assertIOEither $ connectProjectM36 connInfo
  sess' <- assertIOEither $ createSessionAtHead conn' "master"

  val' <- C.validateMerkleHashes sess' conn'
  assertEqual "merkle read again success" (Right ()) val'

  --alter the on-disk representation and check that the hash validation fails
  eGraph <- transactionGraphLoad dbdir emptyTransactionGraph Nothing
  case eGraph of
    Left err -> assertFailure $ "failed to load graph" ++ show err
    Right graph -> do
      let trans = transactionHeadsForGraph graph M.! "master"
          updatedTrans = Transaction (transactionId trans) (transactionInfo trans) updatedSchemas
          updatedSchemas =
            case T.schemas trans of
              Schemas ctx sschemas ->
                let relVars = case resolveDBC' graph ctx relationVariables of
                                Left err -> error ("resolveDBC' failure: " <> show err)
                                Right rv -> rv
                    updatedContext = ctx {
                      relationVariables = ValueMarker (M.insert "malicious" (relVarFromExpr (ExistingRelation relationFalse)) relVars) }
                      in
                Schemas updatedContext sschemas
          maliciousGraph = TransactionGraph malHeads malTransSet
          malHeads = M.insert "master" updatedTrans (transactionHeadsForGraph graph)
          malTransSet = TIdx.insert updatedTrans (transactionsForGraph graph)
          malMerkleHash = calculateMerkleHash updatedTrans maliciousGraph
          regMerkleHash = merkleHash (transactionInfo trans)
      --validate and fail
      let val'' = TG.validateMerkleHashes maliciousGraph
      assertEqual "loaded graph merkle hashes" (Left [MerkleValidationError (transactionId trans) regMerkleHash malMerkleHash]) val''
      --replace the transaction log with one which holds the altered transaction under its original hash
      _ <- transactionGraphPersist NoDiskSync dbdir maliciousGraph

      --read graph from disk
      eConnFail <- connectProjectM36 connInfo
      case eConnFail of
        Left err -> 
          assertEqual "open connection merkle validation" (DatabaseValidationError [MerkleValidationError (transactionId trans) regMerkleHash malMerkleHash]) err
        Right _ -> assertFailure "open connection validation" 

--only Haskell-scripted dbc and atom functions can be serialized                   
testFunctionPersistence :: Test
#if !defined(PM36_HASKELL_SCRIPTING)
testFunctionPersistence = TestCase $ pure ()
#else
testFunctionPersistence = TestCase $
 withSystemTempDirectory "m36testdb" $ \tempdir -> do
  let dbdir = tempdir </> "dbdir"
      connInfo = InProcessConnectionInfo (MinimalPersistence dbdir) emptyNotificationCallback []
  conn <- assertIOEither $ connectProjectM36 connInfo
  sess <- assertIOEither $ createSessionAtHead conn "master"
  let intTCons = PrimitiveTypeConstructor "Int" IntAtomType
      addfunc = AddAtomFunction "testdisk" [
        intTCons, 
        ADTypeConstructor "Either" [ADTypeConstructor "AtomFunctionError" [],
                                    intTCons]] "(\\(x:_) -> pure x) :: [Atom] -> Either AtomFunctionError Atom"
  _ <- assertIOEither $ executeDatabaseContextIOExpr sess conn addfunc
  _ <- assertIOEither $ commit sess conn
  --close conn - pauses indefinitely on Windows
  --re-open the connection to reload the graph
  conn2 <- assertIOEither $ connectProjectM36 connInfo
  sess2 <- assertIOEither $ createSessionAtHead conn2 "master"
  
  res <- executeRelationalExpr sess2 conn2 (MakeRelationFromExprs Nothing (TupleExprs () [TupleExpr (M.singleton "a" (FunctionAtomExpr "testdisk" [NakedAtomExpr (IntAtom 3)] ()))]))
  let expectedRel = mkRelationFromList (attributesFromList [Attribute "a" IntAtomType]) [[IntAtom 3]]
  assertEqual "testdisk dbc function run" expectedRel res

#endif

assertIOEither :: (Show a) => IO (Either a b) -> IO b
assertIOEither x = do
  ret <- x
  case ret of
    Left err -> assertFailure (show err) >> undefined
    Right val -> pure val

-- test that the transaction graph sizes on disk are within expected bounds
-- create an empty database, check its size, add a commit, check the difference in size
testTransactionDirectorySizeGrowth :: Test
testTransactionDirectorySizeGrowth = TestCase $ do
  withSystemTempDirectory "m36testdb" $ \tempdir -> do
    rando <- initStdGen
    Right db <- C.connectProjectM36 (InProcessConnectionInfo (MinimalPersistence (tempdir </> "db")) emptyNotificationCallback [] basicDatabaseContext rando adminRoleName)
    Right sessionId <- C.createSessionAtHead db "master"

    originalDBSize <- getDirectorySize tempdir
    let expectedOriginalSize = 40960 {- sqlite3 loginroles.db -} + 1415
    
    assertBool ("graph with one transaction size- expected: " <> show expectedOriginalSize <> ", actual: " <> show originalDBSize) (originalDBSize <= expectedOriginalSize)

    Right () <- C.executeDatabaseContextExpr sessionId db (Assign "x" (RelationVariable "true" ()))
    Right () <- C.commit sessionId db

    postUpdateDBSize <- getDirectorySize tempdir
    let postUpdateExpectedDiffSize = 1591
        sizeDiff = postUpdateDBSize - originalDBSize 
    assertBool ("graph with two transaction size: " <> show postUpdateDBSize) (sizeDiff <= postUpdateExpectedDiffSize)
        

getDirectorySize :: FilePath -> IO Integer
getDirectorySize dir = do
    contents <- getDirectoryContents dir
    let filteredContents = filter (`notElem` [".", ".."]) contents
    sizes <- forM filteredContents $ \name -> do
        let path' = dir </> name
        isDir <- doesDirectoryExist path'
        if isDir
            then getDirectorySize path'
            else getFileSize path' 
    pure $ sum sizes        

eventAttrs :: Attributes
eventAttrs = attributesFromList [Attribute "id" IntegerAtomType, Attribute "payload" TextAtomType]

insertEvent :: Integer -> DatabaseContextExpr
insertEvent i = Insert "event" (MakeRelationFromExprs Nothing (TupleExprs () [TupleExpr (M.fromList [("id", NakedAtomExpr (IntegerAtom i)),
                                                                                                    ("payload", NakedAtomExpr (TextAtom "created"))])]))

eventWithId :: Integer -> RestrictionPredicateExpr
eventWithId i = AttributeEqualityPredicate "id" (NakedAtomExpr (IntegerAtom i))

-- commits which change a few tuples of a large relation variable are stored as the change, survive reopening with valid hashes, and keep their key
testIncrementalRelVarPersistence :: Test
testIncrementalRelVarPersistence = TestCase $
  withSystemTempDirectory "m36testdb" $ \tempdir -> do
    rando <- initStdGen
    let dbdir = tempdir </> "db"
        connInfo = InProcessConnectionInfo (MinimalPersistence dbdir) emptyNotificationCallback [] basicDatabaseContext rando adminRoleName
        eventCount = 300
        run sess conn expr = assertIOEither (executeDatabaseContextExpr sess conn expr)
        events sess conn = assertIOEither (executeRelationalExpr sess conn (RelationVariable "event" ()))
        expected payloads = mkRelationFromList eventAttrs [[IntegerAtom i, TextAtom payload] | (i, payload) <- payloads]
    conn <- assertIOEither $ connectProjectM36 connInfo
    sess <- assertIOEither $ createSessionAtHead conn "master"
    run sess conn (Define "event" (map NakedAttributeExpr (V.toList (attributesVec eventAttrs))))
    run sess conn (databaseContextExprForUniqueKey "event" ["id"])
    assertIOEither $ commit sess conn
    sizes <- forM [1 .. eventCount] $ \i -> do
      run sess conn (insertEvent i)
      assertIOEither $ commit sess conn
      getFileSize (transactionLogPath dbdir)
    -- the log grows by the same small amount for the first inserts as for the last ones
    let growth = zipWith (-) (drop 1 sizes) sizes
    assertBool ("log growth per commit: " <> show (maximum growth)) (maximum growth < 600)
    -- the key is enforced
    dup <- executeDatabaseContextExpr sess conn (Insert "event" (MakeRelationFromExprs Nothing (TupleExprs () [TupleExpr (M.fromList [("id", NakedAtomExpr (IntegerAtom 1)), ("payload", NakedAtomExpr (TextAtom "duplicate"))])])))
    assertEqual "key violation" (Left (InclusionDependencyCheckError "event_id_key" Nothing)) dup
    -- update and delete single tuples
    run sess conn (Update "event" (M.singleton "payload" (NakedAtomExpr (TextAtom "updated"))) (eventWithId 2))
    assertIOEither $ commit sess conn
    run sess conn (Delete "event" (eventWithId 3))
    assertIOEither $ commit sess conn
    let finalEvents = expected ([(1, "created"), (2, "updated")] <> [(i, "created") | i <- [4 .. eventCount]])
    beforeClose <- events sess conn
    assertEqual "events before reopening" finalEvents (Right beforeClose)
    close conn

    conn' <- assertIOEither $ connectProjectM36 connInfo
    sess' <- assertIOEither $ createSessionAtHead conn' "master"
    val <- C.validateMerkleHashes sess' conn'
    assertEqual "merkle hashes after reopening" (Right ()) val
    afterReopen <- events sess' conn'
    assertEqual "events after reopening" finalEvents (Right afterReopen)
    found <- assertIOEither $ executeRelationalExpr sess' conn' (Restrict (eventWithId 2) (RelationVariable "event" ()))
    assertEqual "lookup by key" (expected [(2, "updated")]) (Right found)
    -- the key is still enforced after reopening and the database keeps accepting commits
    dup' <- executeDatabaseContextExpr sess' conn' (Update "event" (M.singleton "id" (NakedAtomExpr (IntegerAtom 1))) (eventWithId 2))
    assertEqual "key violation after reopening" (Left (InclusionDependencyCheckError "event_id_key" Nothing)) dup'
    run sess' conn' (insertEvent (eventCount + 1))
    assertIOEither $ commit sess' conn'
    close conn'

-- what the types of the relation variables and of the unchanged markers promise, observed from outside:
-- a relation variable which holds its tuples keeps holding them whatever statements change it, a statement which cannot be evaluated fails instead of being stored as a pending expression, and every transaction refers directly to the transaction which holds a value
testStoredRelVarsAndReferences :: Test
testStoredRelVarsAndReferences = TestCase $
  withSystemTempDirectory "m36testdb" $ \tempdir -> do
    rando <- initStdGen
    let dbdir = tempdir </> "db"
        connInfo = InProcessConnectionInfo (MinimalPersistence dbdir) emptyNotificationCallback [] basicDatabaseContext rando adminRoleName
        run sess conn expr = assertIOEither (executeDatabaseContextExpr sess conn expr)
        eventIsStored conn = do
          graph <- transactionGraph_ conn
          case transactionForHead "master" graph of
            Nothing -> assertFailure "no master head" >> pure False
            Just headTrans ->
              case resolveDBC' graph (T.concreteDatabaseContext headTrans) relationVariables of
                Right relVars | Just StoredRelVar{} <- M.lookup "event" relVars -> pure True
                _ -> pure False
    conn <- assertIOEither $ connectProjectM36 connInfo
    sess <- assertIOEither $ createSessionAtHead conn "master"
    run sess conn (Define "event" (map NakedAttributeExpr (V.toList (attributesVec eventAttrs))))
    assertIOEither $ commit sess conn
    forM_ [1 .. 5] $ \i -> do
      run sess conn (insertEvent i)
      assertIOEither $ commit sess conn
    run sess conn (Update "event" (M.singleton "payload" (NakedAtomExpr (TextAtom "updated"))) (eventWithId 2))
    run sess conn (Delete "event" (eventWithId 3))
    -- an assignment of an expression defines the relation variable by that expression; the next insert makes it hold its tuples again
    run sess conn (Assign "event" (Union (RelationVariable "event" ()) (RelationVariable "event" ())))
    run sess conn (insertEvent 6)
    assertIOEither $ commit sess conn
    -- statements which cannot be evaluated are rejected and leave the relation variable as it was
    badDelete <- executeDatabaseContextExpr sess conn (Delete "event" (AttributeEqualityPredicate "nosuchattribute" (NakedAtomExpr (IntegerAtom 1))))
    assertBool ("delete with an invalid predicate: " <> show badDelete) (isLeft badDelete)
    badUpdate <- executeDatabaseContextExpr sess conn (Update "event" (M.singleton "nosuchattribute" (NakedAtomExpr (IntegerAtom 1))) TruePredicate)
    assertBool ("update of a missing attribute: " <> show badUpdate) (isLeft badUpdate)
    badInsert <- executeDatabaseContextExpr sess conn (Insert "event" (RelationVariable "nosuchrelvar" ()))
    assertBool ("insert of an invalid relation: " <> show badInsert) (isLeft badInsert)
    dirty <- disconnectedTransactionIsDirty sess conn
    assertEqual "rejected statements change nothing" (Right False) dirty
    run sess conn (insertEvent 7)
    assertIOEither $ commit sess conn
    stored <- eventIsStored conn
    assertBool "the relation variable still holds its tuples" stored
    remaining <- assertIOEither (executeRelationalExpr sess conn (RelationVariable "event" ()))
    assertEqual "events" (mkRelationFromList eventAttrs [[IntegerAtom i, TextAtom payload] | (i, payload) <- [(1, "created"), (2, "updated"), (4, "created"), (5, "created"), (6, "created"), (7, "created")]]) (Right remaining)

    -- every reference to an earlier transaction names the transaction which holds the value
    graph <- transactionGraph_ conn
    let holds :: String -> (Transaction -> ValueMarker a) -> Transaction -> Assertion
        holds fieldName field trans =
          case field trans of
            ValueMarker _ -> pure ()
            NotChangedSinceMarker tid ->
              case transactionForId tid graph of
                Right origin | valueIsUpdated (field origin) -> pure ()
                _ -> assertFailure (fieldName <> " of " <> show (transactionId trans) <> " refers to " <> show tid <> " which does not hold the value")
        contextField field = field . T.concreteDatabaseContext
    assertBool "enough transactions" (length (transactionListForGraph graph) >= 8)
    forM_ (transactionListForGraph graph) $ \trans -> do
      holds "relationVariables" (contextField relationVariables) trans
      holds "inclusionDependencies" (contextField DBT.inclusionDependencies) trans
      holds "atomFunctions" (contextField atomFunctions) trans
      holds "dbcFunctions" (contextField dbcFunctions) trans
      holds "notifications" (contextField notifications) trans
      holds "typeConstructorMapping" (contextField DBT.typeConstructorMapping) trans
      holds "registeredQueries" (contextField registeredQueries) trans
      holds "acl" (contextField acl) trans
      holds "subschemas" T.subschemas trans

    -- a session which comes to rest on a transaction has changed nothing
    assertIOEither $ executeTransactionGraphExpr sess conn (JumpToHead "master")
    dirtyAfterJump <- disconnectedTransactionIsDirty sess conn
    assertEqual "not dirty after a jump" (Right False) dirtyAfterJump
    close conn

    -- and all of it survives reopening
    conn' <- assertIOEither $ connectProjectM36 connInfo
    stored' <- eventIsStored conn'
    assertBool "the relation variable holds its tuples after reopening" stored'
    close conn'

-- the remains of an interrupted write at the end of the log are ignored and replaced by the next commit
testInterruptedLogWrite :: Test
testInterruptedLogWrite = TestCase $
  withSystemTempDirectory "m36testdb" $ \tempdir -> do
    rando <- initStdGen
    let dbdir = tempdir </> "db"
        connInfo = InProcessConnectionInfo (MinimalPersistence dbdir) emptyNotificationCallback [] basicDatabaseContext rando adminRoleName
        commitX conn val = do
          sess <- assertIOEither $ createSessionAtHead conn "master"
          assertIOEither $ executeDatabaseContextExpr sess conn (Assign "x" (ExistingRelation val))
          assertIOEither $ commit sess conn
        readX conn = do
          sess <- assertIOEither $ createSessionAtHead conn "master"
          executeRelationalExpr sess conn (RelationVariable "x" ())
    conn <- assertIOEither $ connectProjectM36 connInfo
    commitX conn relationTrue
    close conn
    -- half an entry: a length which promises more bytes than follow
    BS.appendFile (transactionLogPath dbdir) (BS.pack [0, 0, 1, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12])

    conn' <- assertIOEither $ connectProjectM36 connInfo
    x <- readX conn'
    assertEqual "committed state survives" (Right relationTrue) x
    commitX conn' relationFalse
    close conn'

    conn'' <- assertIOEither $ connectProjectM36 connInfo
    x' <- readX conn''
    assertEqual "commit after an interrupted write" (Right relationFalse) x'
    close conn''

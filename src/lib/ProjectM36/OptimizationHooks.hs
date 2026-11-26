-- | The places where the relational logic lets the optimization layers in.
--
-- The logic in "ProjectM36.RelationalExpression" is written without knowing how a relation variable holds its tuples or what an index is. At the few points collected here it asks whether something can be done or answered more cheaply. Every function has a trivial implementation, given in its description, which is always correct: replacing a function by it makes the database slower and changes nothing else. A function here must never change what a statement means.
--
-- What is behind these functions today: relation variables which hold their tuples get an index for every key declared on them, and a key is checked by asking the index.
module ProjectM36.OptimizationHooks
  (prepareRelVar,
   prepareRelVars,
   prepareRelVarsForDependency,
   dependenciesAffectedBy,
   decideDependency
  ) where
import ProjectM36.Base
import ProjectM36.Key (keyForInclusionDependency, keysForInclusionDependencies)
import ProjectM36.RelationVariablesMentioned (relVarsMentioned)
import qualified ProjectM36.TupleStore as TStore
import qualified Data.Map as M
import qualified Data.Set as S

-- | Called with every new value of a relation variable before it becomes part of the database context. Returns a value which is equal to the argument.
--
-- Trivial implementation: return the value.
prepareRelVar :: InclusionDependencies -> RelVarName -> RelVarValue -> RelVarValue
prepareRelVar incDeps relVarName rv =
  maybe rv (`withIndexes` rv) (M.lookup relVarName (keysForInclusionDependencies incDeps))

-- | 'prepareRelVar' for all relation variables, for values which did not come through it (when a database is loaded).
--
-- Trivial implementation: return the relation variables.
prepareRelVars :: InclusionDependencies -> RelationVariables -> RelationVariables
prepareRelVars incDeps relVars = M.foldrWithKey prepare relVars (keysForInclusionDependencies incDeps)
  where
    prepare relVarName keys rvs =
      case M.lookup relVarName rvs of
        -- a value which lacks nothing is left where it is (not rebuilt), so that it remains shared with the transaction it came from
        Just rv | lacksIndexes keys rv -> M.insert relVarName (withIndexes keys rv) rvs
        _ -> rvs

-- | Called when an inclusion dependency is added. Returns relation variables which are equal to the argument, or Nothing if there is nothing to prepare.
--
-- Trivial implementation: Nothing.
prepareRelVarsForDependency :: InclusionDependency -> RelationVariables -> Maybe RelationVariables
prepareRelVarsForDependency incDep relVars = do
  (relVarName, key) <- keyForInclusionDependency incDep
  rv <- M.lookup relVarName relVars
  if lacksIndexes [key] rv then
    Just (M.insert relVarName (withIndexes [key] rv) relVars)
    else
    Nothing

-- | The inclusion dependencies which have to be checked again after the relation variable (and nothing else) has changed: a superset of the dependencies whose outcome can have changed.
--
-- Trivial implementation: all inclusion dependencies.
dependenciesAffectedBy :: RelVarName -> InclusionDependencies -> InclusionDependencies
dependenciesAffectedBy changedRelVar =
  M.filter (\(InclusionDependency subExpr superExpr) -> S.member changedRelVar (relVarsMentioned subExpr) || S.member changedRelVar (relVarsMentioned superExpr))

-- | Whether the inclusion dependency holds for the relation variables, if that can be told without evaluating it.
--
-- Trivial implementation: Nothing.
decideDependency :: InclusionDependency -> RelationVariables -> Maybe Bool
decideDependency incDep relVars = do
  (relVarName, key) <- keyForInclusionDependency incDep
  StoredRelVar store <- M.lookup relVarName relVars
  TStore.storeIsUnique key store

-- | Add the indexes for the keys which are missing. A value which has them all is returned as it is.
withIndexes :: [S.Set AttributeName] -> RelVarValue -> RelVarValue
withIndexes keys rv
  | lacksIndexes keys rv, StoredRelVar store <- rv = StoredRelVar (foldr TStore.storeEnsureIndex store keys)
  | otherwise = rv

-- | Whether the relation variable holds its tuples and lacks an index for one of the keys.
lacksIndexes :: [S.Set AttributeName] -> RelVarValue -> Bool
lacksIndexes keys (StoredRelVar store) = not (all (`TStore.storeHasIndex` store) keys)
lacksIndexes _ DerivedRelVar{} = False

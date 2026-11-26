module ProjectM36.Key where
import ProjectM36.Base
import ProjectM36.Relation
import qualified Data.Set as S
import qualified Data.Map as M
import qualified Data.Text as T
#if __GLASGOW_HASKELL__ < 804
import Data.Monoid
#endif

{-
keys can be implemented using inclusion dependencies as well: the count of the projection of the keys' attributes must be equal to the count of the tuples- p. 120 Database in Depth

example: 
:showexpr ((relation{tuple{}}:{a:=S}):{b:=count(@a)}){b}
┌─┐
│b│
├─┤
│5│
└─┘
((relation{tuple{}}:{a:=S{S#}}):{b:=count(@a)}){b}
┌─┐
│b│
├─┤
│5│
└─┘
-}

-- | Create a uniqueness constraint for the attribute names and relational expression. Note that constraint can span multiple relation variables.
inclusionDependencyForKey :: AttributeNames -> RelationalExpr -> InclusionDependency
inclusionDependencyForKey attrNames relExpr = --InclusionDependency name (exprCount relExpr) (exprCount (projectedOnKeys relExpr))
 InclusionDependency equalityExpr (ExistingRelation relationFalse)
  where 
    projectedOnKeys = Project attrNames
    exprAsSubRelation expr = Extend (AttributeExtendTupleExpr "a" (RelationAtomExpr expr)) (ExistingRelation relationTrue)
    exprCount expr = projectionForCount (Extend (AttributeExtendTupleExpr "b" (FunctionAtomExpr "count" [AttributeAtomExpr "a"] () )) (exprAsSubRelation expr))
    projectionForCount = Project (AttributeNames $ S.fromList ["b"])
    equalityExpr = NotEquals (exprCount relExpr) (exprCount (projectedOnKeys relExpr))

-- | If the inclusion dependency is a uniqueness constraint made by 'inclusionDependencyForKey' over a single relation variable, return the relation variable and the attributes of the key. Such constraints can be checked with an index instead of by evaluating the constraint.
keyForInclusionDependency :: InclusionDependency -> Maybe (RelVarName, S.Set AttributeName)
keyForInclusionDependency incDep =
  case incDep of
    InclusionDependency (NotEquals _ (Project _ (Extend _ (Extend (AttributeExtendTupleExpr _ (RelationAtomExpr (Project attrNames@(AttributeNames names) rvExpr@(RelationVariable rvName ())))) _)))) _
      | incDep == inclusionDependencyForKey attrNames rvExpr -> Just (rvName, names)
    _ -> Nothing

-- | The keys declared by the inclusion dependencies, by relation variable.
keysForInclusionDependencies :: InclusionDependencies -> M.Map RelVarName [S.Set AttributeName]
keysForInclusionDependencies incDeps =
  M.fromListWith (<>) [(rvName, [names]) | Just (rvName, names) <- map keyForInclusionDependency (M.elems incDeps)]

-- | Create a 'DatabaseContextExpr' which can be used to add a uniqueness constraint to attributes on one relation variable.
databaseContextExprForUniqueKey :: RelVarName -> [AttributeName] -> DatabaseContextExpr
databaseContextExprForUniqueKey rvName attrNames = AddInclusionDependency (rvName <> "_" <> cols <>  "_key") $ inclusionDependencyForKey (AttributeNames (S.fromList attrNames)) (RelationVariable rvName ())
  where
    cols = T.intercalate "_" attrNames

-- | Create a foreign key constraint from the first relation variable and attributes to the second.
databaseContextExprForForeignKey :: IncDepName -> (RelVarName, [AttributeName]) -> (RelVarName, [AttributeName]) -> DatabaseContextExpr
databaseContextExprForForeignKey fkName infoA infoB =
  AddInclusionDependency fkName (inclusionDependencyForForeignKey infoA infoB)
  
inclusionDependencyForForeignKey :: (RelVarName, [AttributeName]) -> (RelVarName, [AttributeName]) -> InclusionDependency
inclusionDependencyForForeignKey (rvA, attrsA) (rvB, attrsB) = 
  InclusionDependency (
    renameIfNecessary attrsB attrsA (Project (attrsL attrsA)
                                     (RelationVariable rvA ()))) (
    Project (attrsL attrsB) (RelationVariable rvB ()))
  where
    attrsL = AttributeNames . S.fromList    
    renameIfNecessary attrsExpected attrsExisting expr = foldr folder expr (zip attrsExpected attrsExisting)
    folder (attrExpected, attrExisting) expr = if attrExpected == attrExisting then
                                                   expr
                                                 else
                                                   Rename (S.singleton (attrExisting, attrExpected)) expr

-- if the constraint is a foreign key constraint, then return the relations and attributes involved - this only detects foreign keys created with `databaseContextExprForForeignKey`
isForeignKeyFor :: InclusionDependency -> (RelVarName, [AttributeName]) -> (RelVarName, [AttributeName]) -> Bool
isForeignKeyFor incDep infoA infoB = incDep == checkIncDep
  where
    checkIncDep = inclusionDependencyForForeignKey infoA infoB





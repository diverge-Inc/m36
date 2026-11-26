-- | The value of a relation variable ('RelVarValue') as far as the relational logic needs to know it.
--
-- The logic distinguishes a relation variable which holds its tuples from one which is defined by an expression, and nothing more. How the tuples are held (the store, its indexes, what two versions share) stays behind the functions of this module, so that "ProjectM36.RelationalExpression" can be read and changed without knowing about any of it.
--
-- Meant to be imported qualified.
module ProjectM36.RelVarValue
  (holdsTuples,
   emptyHolding,
   holding,
   holdingLike,
   sameTuples
  ) where
import ProjectM36.Base
import qualified ProjectM36.TupleStore as TStore

-- | Whether the relation variable holds its tuples (as opposed to being defined by an expression which is evaluated when the relation variable is read).
holdsTuples :: RelVarValue -> Bool
holdsTuples StoredRelVar{} = True
holdsTuples DerivedRelVar{} = False

-- | A relation variable with the attributes which holds no tuples.
emptyHolding :: Attributes -> RelVarValue
emptyHolding = StoredRelVar . TStore.emptyStore

-- | A relation variable which holds the tuples of the relation. Nothing if the tuples of the relation do not fit its attributes.
holding :: Relation -> Maybe RelVarValue
holding rel = StoredRelVar <$> TStore.storeFromRelation rel

-- | The next value of a relation variable: it holds the tuples of the relation the way the previous value held its own. If the relation was computed from the previous value by the relational operators, the new value shares with the previous one whatever did not change, and making it costs nothing.
holdingLike :: RelVarValue -> Relation -> Maybe RelVarValue
holdingLike (StoredRelVar previous) rel = StoredRelVar <$> TStore.storeFromRelationLike previous rel
holdingLike DerivedRelVar{} rel = holding rel

-- | Whether both relation variables hold their tuples and hold the same ones. When one value was computed from the other, this takes time proportional to their difference.
sameTuples :: RelVarValue -> RelVarValue -> Bool
sameTuples (StoredRelVar a) (StoredRelVar b) = TStore.storeSameTuples a b
sameTuples _ _ = False

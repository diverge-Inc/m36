{-# LANGUAGE BangPatterns #-}
-- | Operations on the materialized tuple set representation ('TupleStore') used for the value of relation variables.
--
-- A store is a persistent (structure-sharing) hash set of atom vectors. Deriving a new version of a relation variable by inserting or deleting a few tuples costs time and memory proportional to the number of changed tuples, and two versions can be compared ('storeDiff') in time proportional to their difference. That is what lets a commit write, hash, and check only what it changed.
module ProjectM36.TupleStore where
import ProjectM36.Base
import qualified Data.HashSet as HS
import qualified Data.HashMap.Strict as HM
import qualified Data.HashMap.Internal as HMI
import qualified Data.HashMap.Internal.Array as HA
import qualified Data.Vector as V
import qualified Data.Map as M
import qualified Data.Set as S
import Data.Bits
import Data.List (foldl')
import Data.Maybe (mapMaybe)

type AtomVector = V.Vector Atom

-- | An empty store with the attributes.
emptyStore :: Attributes -> RelationTupleSet
emptyStore attrs = TupleStore attrs 0 HS.empty M.empty

isStore :: RelationTupleSet -> Bool
isStore TupleStore{} = True
isStore TupleList{} = False

-- | The atoms of the tuple in the order of the attributes argument, or Nothing if the tuple lacks one of the attributes.
atomsInOrder :: Attributes -> RelationTuple -> Maybe AtomVector
atomsInOrder attrs (RelationTuple tupAttrs atoms)
  | attributesVec tupAttrs == attributesVec attrs = Just atoms
  | V.length (attributesVec tupAttrs) /= V.length (attributesVec attrs) = Nothing
  | otherwise = V.mapM pick (attributesVec attrs)
  where
    name (Attribute n _) = n
    pick attr = do
      i <- V.findIndex (\a -> name a == name attr) (attributesVec tupAttrs)
      atoms V.!? i

-- | Build a store from tuples. Nothing if a tuple does not have exactly the attributes.
storeFromTuples :: Attributes -> [RelationTuple] -> Maybe RelationTupleSet
storeFromTuples attrs tups = storeFromVectors attrs <$> mapM (atomsInOrder attrs) tups

-- | Build a store from atom vectors which are already in the order of the attributes.
storeFromVectors :: Attributes -> [AtomVector] -> RelationTupleSet
storeFromVectors attrs = storeInsertVectors (emptyStore attrs)

-- | Insert atom vectors (in the attribute order of the store). Tuples already present are skipped.
storeInsertVectors :: RelationTupleSet -> [AtomVector] -> RelationTupleSet
storeInsertVectors (TupleStore attrs size0 tups0 idxs0) vecs =
  let (size', tups', idxs') = foldl' ins (size0, HS.toMap tups0, idxs0) vecs
  in TupleStore attrs size' (HS.fromMap tups') idxs'
  where
    ins acc@(!size, !tups, !idxs) vec =
      let h = HMI.hash vec in
      case HMI.lookup' h vec tups of
        Just () -> acc
        Nothing -> (size + 1, HMI.insert' h vec () tups, M.map (indexInsert vec) idxs)
storeInsertVectors (TupleList tups) _ = TupleList tups -- not a store; callers check with 'isStore'

-- | Delete atom vectors (in the attribute order of the store). Missing tuples are skipped.
storeDeleteVectors :: RelationTupleSet -> [AtomVector] -> RelationTupleSet
storeDeleteVectors (TupleStore attrs size0 tups0 idxs0) vecs =
  let (size', tups', idxs') = foldl' del (size0, HS.toMap tups0, idxs0) vecs
  in TupleStore attrs size' (HS.fromMap tups') idxs'
  where
    del acc@(!size, !tups, !idxs) vec =
      let h = HMI.hash vec in
      case HMI.lookup' h vec tups of
        Nothing -> acc
        Just () -> (size - 1, HMI.delete' h vec tups, M.map (indexDelete vec) idxs)
storeDeleteVectors (TupleList tups) _ = TupleList tups

-- | Insert the tuples of any tuple set into a store. Nothing if the first argument is not a store or a tuple does not have the attributes of the store.
storeInsertTupleSet :: RelationTupleSet -> RelationTupleSet -> Maybe RelationTupleSet
storeInsertTupleSet store@(TupleStore attrs _ _ _) other =
  case other of
    TupleStore otherAttrs _ otherTups _ | attributesVec otherAttrs == attributesVec attrs ->
                                            Just (storeInsertVectors store (HS.toList otherTups))
    _ -> storeInsertVectors store <$> mapM (atomsInOrder attrs) (asList other)
storeInsertTupleSet TupleList{} _ = Nothing

storeSize :: RelationTupleSet -> Maybe Int
storeSize (TupleStore _ size _ _) = Just size
storeSize TupleList{} = Nothing

-- | Convert the body of the relation to a store unless it is one already. Nothing if the tuples do not match the attributes.
materializeRelation :: Relation -> Maybe Relation
materializeRelation rel@(Relation _ TupleStore{}) = Just rel
materializeRelation (Relation attrs (TupleList tups)) = Relation attrs <$> storeFromTuples attrs tups

-- | Like 'materializeRelation' but carry over the indexes of an earlier value of the same relation variable.
materializeRelationLike :: RelationTupleSet -> Relation -> Maybe Relation
materializeRelationLike previous rel = do
  Relation attrs store <- materializeRelation rel
  pure (Relation attrs (foldl' (flip storeEnsureIndex) store (M.keys (storeIndexes previous))))

storeIndexes :: RelationTupleSet -> TupleStoreIndexes
storeIndexes (TupleStore _ _ _ idxs) = idxs
storeIndexes TupleList{} = M.empty

-- * comparing versions

-- | The difference between two versions of a tuple set: (tuples only in the first, tuples only in the second).
-- Subtrees shared by both versions are skipped, so this is proportional to the number of differing tuples when one version was derived from the other.
storeDiff :: HS.HashSet AtomVector -> HS.HashSet AtomVector -> ([AtomVector], [AtomVector])
storeDiff a b = go (HS.toMap a) (HS.toMap b) ([], [])
  where
    go :: HM.HashMap AtomVector () -> HM.HashMap AtomVector () -> ([AtomVector], [AtomVector]) -> ([AtomVector], [AtomVector])
    -- both nodes must be evaluated before their pointers are compared; an unevaluated argument would never be pointer-equal to anything
    go !x !y acc | ptrEquals x y = acc
    go HMI.Empty y (l, r) = (l, HM.keys y ++ r)
    go x HMI.Empty (l, r) = (HM.keys x ++ l, r)
    go (HMI.BitmapIndexed bx ax) (HMI.BitmapIndexed by ay) acc = children bx ax by ay acc
    go (HMI.Full ax) (HMI.Full ay) acc = children (fullMask ax) ax (fullMask ay) ay acc
    go (HMI.Full ax) (HMI.BitmapIndexed by ay) acc = children (fullMask ax) ax by ay acc
    go (HMI.BitmapIndexed bx ax) (HMI.Full ay) acc = children bx ax (fullMask ay) ay acc
    -- leaves, collisions, or nodes of different kinds: both cover the same hash prefix, so compare their keys directly
    go x y (l, r) =
      let kx = HM.keys x
          ky = HM.keys y
          sx = HS.fromList kx
          sy = HS.fromList ky
      in (filter (not . (`HS.member` sy)) kx ++ l, filter (not . (`HS.member` sx)) ky ++ r)
    fullMask ary = (1 `unsafeShiftL` HA.length ary) - 1 :: Word
    children bx ax by ay acc0 = goBits (bx .|. by) acc0
      where
        goBits 0 acc = acc
        goBits remaining acc@(l, r) =
          let m = remaining .&. negate remaining -- lowest set bit
              rest = remaining .&. complement m
              child bm ary = HA.index ary (popCount (bm .&. (m - 1)))
              inX = bx .&. m /= 0
              inY = by .&. m /= 0
              acc' | inX && inY = go (child bx ax) (child by ay) acc
                   | inX = (HM.keys (child bx ax) ++ l, r)
                   | otherwise = (l, HM.keys (child by ay) ++ r)
          in goBits rest acc'

-- * indexes

-- | Positions of the attribute names (ascending by name) in the attributes, or Nothing if one is missing.
indexPositions :: Attributes -> S.Set AttributeName -> Maybe (V.Vector Int)
indexPositions attrs names = V.fromList <$> mapM pos (S.toAscList names)
  where
    pos n = V.findIndex (\(Attribute an _) -> an == n) (attributesVec attrs)

indexKey :: V.Vector Int -> AtomVector -> AtomVector
indexKey positions vec = V.map (V.unsafeIndex vec) positions

indexInsert :: AtomVector -> TupleStoreIndex -> TupleStoreIndex
indexInsert vec (TupleStoreIndex positions m dups) =
  let key = indexKey positions vec in
  case HM.lookup key m of
    Nothing -> TupleStoreIndex positions (HM.insert key [vec] m) dups
    Just [one] -> TupleStoreIndex positions (HM.insert key [vec, one] m) (dups + 1)
    Just more -> TupleStoreIndex positions (HM.insert key (vec : more) m) dups

indexDelete :: AtomVector -> TupleStoreIndex -> TupleStoreIndex
indexDelete vec (TupleStoreIndex positions m dups) =
  let key = indexKey positions vec in
  case HM.lookup key m of
    Nothing -> TupleStoreIndex positions m dups
    Just bucket ->
      case filter (/= vec) bucket of
        [] -> TupleStoreIndex positions (HM.delete key m) dups
        remaining@[_] -> TupleStoreIndex positions (HM.insert key remaining m) (if length bucket > 1 then dups - 1 else dups)
        remaining -> TupleStoreIndex positions (HM.insert key remaining m) dups

-- | Add an index over the attribute names unless the store already has it. No-op if the argument is not a store or lacks one of the attributes.
storeEnsureIndex :: S.Set AttributeName -> RelationTupleSet -> RelationTupleSet
storeEnsureIndex names store@(TupleStore attrs size tups idxs)
  | M.member names idxs = store
  | otherwise =
      case indexPositions attrs names of
        Nothing -> store
        Just positions ->
          let idx = HS.foldl' (flip indexInsert) (TupleStoreIndex positions HM.empty 0) tups
          in TupleStore attrs size tups (M.insert names idx idxs)
storeEnsureIndex _ tupSet = tupSet

-- | The tuples whose indexed attributes equal the atoms (given in ascending order of attribute name), if the store has an index on exactly those attributes.
storeIndexLookup :: S.Set AttributeName -> AtomVector -> RelationTupleSet -> Maybe [RelationTuple]
storeIndexLookup names key (TupleStore attrs _ _ idxs) = do
  idx <- M.lookup names idxs
  pure (map (RelationTuple attrs) (HM.lookupDefault [] key (tsiMap idx)))
storeIndexLookup _ _ TupleList{} = Nothing

-- | Find the tuples matching attribute/atom equalities using an index over a subset of the given attributes. The result may contain tuples which do not match the equalities which are not covered by the index, so the caller still applies its full predicate.
storeLookupByEqualities :: M.Map AttributeName Atom -> RelationTupleSet -> Maybe [RelationTuple]
storeLookupByEqualities equalities store@(TupleStore _ _ _ idxs) =
  case mapMaybe usable (M.keys idxs) of
    [] -> Nothing
    names : _ -> storeIndexLookup names (V.fromList (map (equalities M.!) (S.toAscList names))) store
  where
    usable names = if not (S.null names) && all (`M.member` equalities) names then Just names else Nothing
storeLookupByEqualities _ TupleList{} = Nothing

-- | The attribute = constant terms which every tuple satisfying the predicate must satisfy.
predicateEqualities :: RestrictionPredicateExprBase a -> M.Map AttributeName Atom
predicateEqualities (AndPredicate exprA exprB) = M.union (predicateEqualities exprA) (predicateEqualities exprB)
predicateEqualities (AttributeEqualityPredicate attrName (NakedAtomExpr atom)) = M.singleton attrName atom
predicateEqualities _ = M.empty

-- | Whether the attribute names are a key of the tuples: Just True/False if the store has an index on them, Nothing if it cannot tell cheaply.
storeIsUnique :: S.Set AttributeName -> RelationTupleSet -> Maybe Bool
storeIsUnique names (TupleStore _ _ _ idxs) = (\idx -> tsiDuplicates idx == 0) <$> M.lookup names idxs
storeIsUnique _ TupleList{} = Nothing

{-# LANGUAGE BangPatterns #-}
-- | Operations on 'TupleStore', the materialized form in which a relation variable holds its tuples.
--
-- A store is a persistent (structure-sharing) hash set of atom vectors. Deriving a new version of a relation variable by inserting or deleting a few tuples costs time and memory proportional to the number of changed tuples, and two versions can be compared ('storeDiff') in time proportional to their difference. That is what lets a commit write, hash, and check only what it changed.
--
-- The functions which change a store take a store and the tuples to add or remove and return a store. There is no way to express "the old value and something more" other than as the new set of tuples, so the value of a relation variable cannot grow into a chain of pending operations.
module ProjectM36.TupleStore where
import ProjectM36.Base
import ProjectM36.PointerEquality
import qualified ProjectM36.Attribute as A
import qualified Data.HashSet as HS
import qualified Data.HashMap.Strict as HM
import qualified Data.HashMap.Internal as HMI
import qualified Data.HashMap.Internal.Array as HA
import qualified Data.Vector as V
import qualified Data.Map.Strict as M
import qualified Data.Set as S
import Data.Bits
import Data.List (foldl')
import Data.Maybe (mapMaybe)

type AtomVector = V.Vector Atom

-- | An empty store with the attributes.
emptyStore :: Attributes -> TupleStore
emptyStore attrs = TupleStore attrs 0 HS.empty NoIndexes

-- | An empty store with the attributes and (empty) indexes of the argument.
storeEmptyLike :: TupleStore -> TupleStore
storeEmptyLike previous = foldr storeEnsureIndex (emptyStore (storeAttributes previous)) (indexedAttributeNames (storeIndexes previous))

-- | The tuples of the store.
storeTupleList :: TupleStore -> [RelationTuple]
storeTupleList = asList . StoredTuples

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
storeFromTuples :: Attributes -> [RelationTuple] -> Maybe TupleStore
storeFromTuples attrs tups = storeFromVectors attrs <$> mapM (atomsInOrder attrs) tups

-- | Build a store from atom vectors which are already in the order of the attributes.
storeFromVectors :: Attributes -> [AtomVector] -> TupleStore
storeFromVectors attrs = storeInsertVectors (emptyStore attrs)

-- | The body of the relation as a store. Constant time if it is one already. Nothing if the tuples do not match the attributes.
storeFromRelation :: Relation -> Maybe TupleStore
storeFromRelation (Relation _ (StoredTuples store)) = Just store
storeFromRelation (Relation attrs (TupleList tups)) = storeFromTuples attrs tups

-- | The body of the relation as a store which holds it the way an earlier value of the same relation variable was held: with the same order of attributes (if the attributes are still the same) and the same indexes. Constant time if the body is a store which was derived from the earlier one.
storeFromRelationLike :: TupleStore -> Relation -> Maybe TupleStore
storeFromRelationLike previous rel@(Relation attrs tupSet) =
  case tupSet of
    StoredTuples store | attributesVec (storeAttributes store) == attributesVec (storeAttributes previous) -> Just (withIndexes store)
    _ | A.attributesEqual attrs (storeAttributes previous) -> storeInsertTupleSet (storeEmptyLike previous) tupSet
      | otherwise -> withIndexes <$> storeFromRelation rel
  where
    withIndexes store = foldl' (flip storeEnsureIndex) store (indexedAttributeNames (storeIndexes previous))

-- | Whether two stores hold the same tuples. When one store was derived from the other, this takes time proportional to their difference.
storeSameTuples :: TupleStore -> TupleStore -> Bool
storeSameTuples a b
  | attributesVec (storeAttributes a) == attributesVec (storeAttributes b) =
      storeSize a == storeSize b && case storeDiff (storeTuples a) (storeTuples b) of
                                      ([], []) -> True
                                      _ -> False
  | otherwise = a == b

-- | Insert atom vectors (in the attribute order of the store). Tuples already present are skipped.
storeInsertVectors :: TupleStore -> [AtomVector] -> TupleStore
storeInsertVectors (TupleStore attrs size0 tups0 idxs0) vecs =
  let (size', tups', idxs') = foldl' ins (size0, HS.toMap tups0, idxs0) vecs
  in TupleStore attrs size' (HS.fromMap tups') idxs'
  where
    ins acc@(!size, !tups, !idxs) vec =
      let h = HMI.hash vec in
      case HMI.lookup' h vec tups of
        Just () -> acc
        Nothing -> (size + 1, HMI.insert' h vec () tups, mapIndexes (indexInsert vec) idxs)

-- | Delete atom vectors (in the attribute order of the store). Missing tuples are skipped.
storeDeleteVectors :: TupleStore -> [AtomVector] -> TupleStore
storeDeleteVectors (TupleStore attrs size0 tups0 idxs0) vecs =
  let (size', tups', idxs') = foldl' del (size0, HS.toMap tups0, idxs0) vecs
  in TupleStore attrs size' (HS.fromMap tups') idxs'
  where
    del acc@(!size, !tups, !idxs) vec =
      let h = HMI.hash vec in
      case HMI.lookup' h vec tups of
        Nothing -> acc
        Just () -> (size - 1, HMI.delete' h vec tups, mapIndexes (indexDelete vec) idxs)

-- | Insert the tuples of any tuple set into a store. Nothing if a tuple does not have the attributes of the store.
storeInsertTupleSet :: TupleStore -> RelationTupleSet -> Maybe TupleStore
storeInsertTupleSet store other =
  case other of
    StoredTuples otherStore | attributesVec (storeAttributes otherStore) == attributesVec (storeAttributes store) ->
                                Just (storeInsertVectors store (HS.toList (storeTuples otherStore)))
    _ -> storeInsertVectors store <$> mapM (atomsInOrder (storeAttributes store)) (asList other)

-- * comparing versions

-- | The difference between two versions of a tuple set: (tuples only in the first, tuples only in the second).
-- Subtrees shared by both versions are skipped, so this is proportional to the number of differing tuples when one version was derived from the other.
storeDiff :: HS.HashSet AtomVector -> HS.HashSet AtomVector -> ([AtomVector], [AtomVector])
storeDiff a b = go (HS.toMap a) (HS.toMap b) ([], [])
  where
    go :: HM.HashMap AtomVector () -> HM.HashMap AtomVector () -> ([AtomVector], [AtomVector]) -> ([AtomVector], [AtomVector])
    go x y acc | ptrEquals (Forced x) (Forced y) = acc
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

-- | The index on exactly these attributes.
lookupIndex :: S.Set AttributeName -> TupleStoreIndexes -> Maybe TupleStoreIndex
lookupIndex _ NoIndexes = Nothing
lookupIndex names (IndexOn idxNames idx rest)
  | idxNames == names = Just idx
  | otherwise = lookupIndex names rest

-- | The attribute names of each index.
indexedAttributeNames :: TupleStoreIndexes -> [S.Set AttributeName]
indexedAttributeNames NoIndexes = []
indexedAttributeNames (IndexOn names _ rest) = names : indexedAttributeNames rest

mapIndexes :: (TupleStoreIndex -> TupleStoreIndex) -> TupleStoreIndexes -> TupleStoreIndexes
mapIndexes _ NoIndexes = NoIndexes
mapIndexes f (IndexOn names idx rest) = IndexOn names (f idx) (mapIndexes f rest)

-- | Add an index, keeping the list in ascending order of the attribute names.
addIndex :: S.Set AttributeName -> TupleStoreIndex -> TupleStoreIndexes -> TupleStoreIndexes
addIndex names idx NoIndexes = IndexOn names idx NoIndexes
addIndex names idx idxs@(IndexOn otherNames otherIdx rest)
  | names < otherNames = IndexOn names idx idxs
  | otherwise = IndexOn otherNames otherIdx (addIndex names idx rest)

-- | Whether the store has an index on exactly these attributes.
storeHasIndex :: S.Set AttributeName -> TupleStore -> Bool
storeHasIndex names store = maybe False (const True) (lookupIndex names (storeIndexes store))

-- | Add an index over the attribute names unless the store already has it (in which case the store is returned as it is, not rebuilt). No-op if the store lacks one of the attributes.
storeEnsureIndex :: S.Set AttributeName -> TupleStore -> TupleStore
storeEnsureIndex names store@(TupleStore attrs size tups idxs)
  | storeHasIndex names store = store
  | otherwise =
      case indexPositions attrs names of
        Nothing -> store
        Just positions ->
          let idx = HS.foldl' (flip indexInsert) (TupleStoreIndex positions HM.empty 0) tups
          in TupleStore attrs size tups (addIndex names idx idxs)

-- | The tuples whose indexed attributes equal the atoms (given in ascending order of attribute name), if the store has an index on exactly those attributes.
storeIndexLookup :: S.Set AttributeName -> AtomVector -> TupleStore -> Maybe [RelationTuple]
storeIndexLookup names key store = do
  idx <- lookupIndex names (storeIndexes store)
  pure (map (RelationTuple (storeAttributes store)) (HM.lookupDefault [] key (tsiMap idx)))

-- | Find the tuples matching attribute/atom equalities using an index over a subset of the given attributes. The result may contain tuples which do not match the equalities which are not covered by the index, so the caller still applies its full predicate.
storeLookupByEqualities :: M.Map AttributeName Atom -> TupleStore -> Maybe [RelationTuple]
storeLookupByEqualities equalities store =
  case mapMaybe usable (indexedAttributeNames (storeIndexes store)) of
    [] -> Nothing
    names : _ -> storeIndexLookup names (V.fromList (map (equalities M.!) (S.toAscList names))) store
  where
    usable names = if not (S.null names) && all (`M.member` equalities) names then Just names else Nothing

-- | Whether the attribute names are a key of the tuples: Just True/False if the store has an index on them, Nothing if it cannot tell cheaply.
storeIsUnique :: S.Set AttributeName -> TupleStore -> Maybe Bool
storeIsUnique names store = (\idx -> tsiDuplicates idx == 0) <$> lookupIndex names (storeIndexes store)

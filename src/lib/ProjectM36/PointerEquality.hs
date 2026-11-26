{-# LANGUAGE MagicHash, UnliftedDatatypes, StandaloneKindSignatures, DataKinds #-}
-- | Pointer equality which cannot be handed an unevaluated value.
--
-- Two versions of a persistent data structure share the parts which did not change, so "are these the same object?" lets a comparison skip the shared parts. The question is only meaningful for evaluated values: an unevaluated value is a suspended computation, which is never the same object as the value it will become, so comparing one silently answers "different" and the comparison walks everything. The argument type here rules that out.
module ProjectM36.PointerEquality (Forced(Forced), ptrEquals) where
import GHC.Exts (reallyUnsafePtrEquality#, isTrue#, UnliftedType)
import Data.Kind (Type)

-- | A value which has been evaluated (to weak head normal form). The type is unlifted, so there is no such thing as an unevaluated 'Forced', and its field is strict, so the value inside has been evaluated by the time the 'Forced' exists.
type Forced :: Type -> UnliftedType
data Forced a = Forced !a

-- | 'True' implies that both arguments are the same value, 'False' implies nothing.
ptrEquals :: Forced a -> Forced a -> Bool
ptrEquals (Forced a) (Forced b) = isTrue# (reallyUnsafePtrEquality# a b)
{-# INLINE ptrEquals #-}

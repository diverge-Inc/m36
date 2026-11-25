{-# LANGUAGE CPP #-}
-- | Compatibility shims across streamly-core versions.
--
-- streamly-core 0.3 (streamly 0.11) renamed the nested-stream wrapper from
-- 'CrossStream'/'mkCross' to 'Nested'. Supporting both lets project-m36 build
-- against streamly 0.10 (as shipped by nixpkgs) as well as streamly 0.11.
module ProjectM36.Streaming.Compat (nested) where

import qualified Streamly.Internal.Data.Stream as SD

-- | Wrap a stream so that it can be bound monadically ('SD.unCross' unwraps it).
#if MIN_VERSION_streamly_core(0,3,0)
nested :: SD.Stream m a -> SD.Nested m a
nested = SD.Nested
#else
nested :: SD.Stream m a -> SD.CrossStream m a
nested = SD.mkCross
#endif

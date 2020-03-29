{-# LANGUAGE Strict, StrictData #-}
{-# LANGUAGE FlexibleContexts #-}

module Data.Floating.Ryu.Common
    ( (.>>)
    , (.<<)
    , mask
    , asWord
    , pmap
    , special
    , decimalLength9
    , decimalLength17
    , pow5bits
    , log10pow2
    , log10pow5
    , multipleOfPowerOf5_32
    , multipleOfPowerOf5_64
    , multipleOfPowerOf2
    , writeSign
    , appendNDigits
    , append9Digits
    , toCharsScientific
    , toCharsFixed
    , toChars
    ) where

import Data.Array.Unboxed
import Data.Array.Base (unsafeAt)
import Data.Bits
import Data.Char (chr, ord)
import Data.Int (Int32)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Internal as BS
import qualified Data.ByteString.Builder as BB
import qualified Data.ByteString.Builder.Extra as BBE
import qualified Data.ByteString.Lazy.Char8 as BL
import GHC.Word (Word8, Word16, Word32, Word64)
import Foreign.ForeignPtr (ForeignPtr, withForeignPtr)
import Foreign.Marshal.Utils (moveBytes)
import Foreign.Ptr (Ptr, minusPtr, plusPtr)
import Foreign.Storable (poke)
import System.IO.Unsafe (unsafePerformIO)

(.>>) :: (Bits a, Integral b) => a -> b -> a
a .>> s = shiftR a (fromIntegral s)

(.<<) :: (Bits a, Integral b) => a -> b -> a
a .<< s = shiftL a (fromIntegral s)

mask :: (Bits a, Integral a) => a -> a
mask = flip (-) 1 . (.<<) 1

asWord :: Integral w => Bool -> w
asWord = fromIntegral . fromEnum

pmap :: (a -> c) -> (a, b) -> (c, b)
pmap f (a, b) = (f a, b)

-- Returns the number of decimal digits in v, which must not contain more than 9 digits.
decimalLength9 :: Integral a => a -> Int
decimalLength9 v
  | v >= 100000000 = 9
  | v >= 10000000 = 8
  | v >= 1000000 = 7
  | v >= 100000 = 6
  | v >= 10000 = 5
  | v >= 1000 = 4
  | v >= 100 = 3
  | v >= 10 = 2
  | otherwise = 1

-- Returns the number of decimal digits in v, which must not contain more than 17 digits.
decimalLength17 :: Integral a => a -> Int
decimalLength17 v
  | v >= 10000000000000000 = 17
  | v >= 1000000000000000 = 16
  | v >= 100000000000000 = 15
  | v >= 10000000000000 = 14
  | v >= 1000000000000 = 13
  | v >= 100000000000 = 12
  | v >= 10000000000 = 11
  | v >= 1000000000 = 10
  | v >= 100000000 = 9
  | v >= 10000000 = 8
  | v >= 1000000 = 7
  | v >= 100000 = 6
  | v >= 10000 = 5
  | v >= 1000 = 4
  | v >= 100 = 3
  | v >= 10 = 2
  | otherwise = 1

--         Sign -> Exp  -> Mantissa
special :: Bool -> Bool -> Bool   ->   String
special    _       _       True   =    "NaN"
special    True    False   _      =    "-0E0"
special    False   False   _      =    "0E0"
special    True    True    _      =    "-Infinity"
special    False   True    _      =    "Infinity"


-- Returns e == 0 ? 1 : ceil(log_2(5^e)); requires 0 <= e <= 3528.
pow5bits :: (Bits a, Integral a) => a -> a
pow5bits e = (e * 1217359) .>> 19 + 1

-- Returns floor(log_10(2^e)); requires 0 <= e <= 1650.
log10pow2 :: (Bits a, Integral a) => a -> a
log10pow2 e = (e * 78913) .>> 18

-- Returns floor(log_10(5^e)); requires 0 <= e <= 2620.
log10pow5 :: (Bits a, Integral a) => a -> a
log10pow5 e = (e * 732928) .>> 20

pow5_32 :: UArray Int Word32
pow5_32 = listArray (0, 9) [5 ^ x | x <- [0..9]]

pow5_64 :: UArray Int Word64
pow5_64 = listArray (0, 21) [5 ^ x | x <- [0..21]]

multipleOfPowerOf5_32 :: Word32 -> Word32 -> Bool
multipleOfPowerOf5_32 value p = value `mod` (pow5_32 `unsafeAt` fromIntegral p) == 0

multipleOfPowerOf5_64 :: Word64 -> Word64 -> Bool
multipleOfPowerOf5_64 value p = value `mod` (pow5_64 `unsafeAt` fromIntegral p) == 0

multipleOfPowerOf2 :: (Bits a, Integral a) => a -> a -> Bool
multipleOfPowerOf2 value p = value .&. mask p == 0

toAscii :: (Integral a, Integral b) => a -> b
toAscii = fromIntegral . (+) (fromIntegral $ ord '0')

class (IArray UArray a, FiniteBits a, Integral a) => Mantissa a where
    decimalLength :: a -> Int
    max_representable_pow10 :: a -> Int32
    max_shifted_mantissa :: UArray Int32 a

instance Mantissa Word32 where
    decimalLength = decimalLength9
    max_representable_pow10 = const 10
    max_shifted_mantissa = listArray (0, 10) [ (2^24 - 1) `div` 5^x | x <- [0..10] ]

instance Mantissa Word64 where
    decimalLength = decimalLength17
    max_representable_pow10 = const 22
    max_shifted_mantissa = listArray (0, 22) [ (2^53- 1) `div` 5^x | x <- [0..22] ]

digit_table :: Array Int32 BS.ByteString
digit_table = listArray (0, 99) [ BS.packBytes [toAscii a, toAscii b] | a <- [0..9], b <- [0..9] ]

copy :: BS.ByteString -> Ptr Word8 -> IO ()
copy (BS.PS fp off len) ptr =
  withForeignPtr fp $ \src -> do
    BS.memcpy ptr (src `plusPtr` off) len
    return ()

-- for loop recursively...
writeMantissa :: (Mantissa a) => Ptr Word8 -> Int -> Int -> a -> IO (Ptr Word8)
writeMantissa ptr olength i mantissa
  | mantissa >= 10000 = do
      let (m', c) = mantissa `divMod` 10000
          (c1, c0) = c `divMod` 100
      copy (digit_table ! fromIntegral c0) (ptr `plusPtr` (olength - i - 1))
      copy (digit_table ! fromIntegral c1) (ptr `plusPtr` (olength - i - 3))
      writeMantissa ptr olength (i + 4) m'
  | mantissa >= 100 = do
      let (m', c) = mantissa `divMod` 100
      copy (digit_table ! fromIntegral c) (ptr `plusPtr` (olength - i - 1))
      writeMantissa ptr olength (i + 2) m'
  | mantissa >= 10 = do
      let bs = digit_table ! fromIntegral mantissa
      poke (ptr `plusPtr` (olength  - i)) (BS.last bs)
      poke ptr (BS.head bs)
      finalize ptr
  | otherwise = do
      poke ptr (toAscii mantissa :: Word8)
      finalize ptr
  where finalize p = if olength > 1
                        then poke (p `plusPtr` 1) (BS.c2w '.') >> return (p `plusPtr` (olength + 1))
                        else return (p `plusPtr` 1)

writeExponent :: Ptr Word8 -> Int32 -> IO (Ptr Word8)
writeExponent ptr exponent
  | exponent >= 100 = do
      let (e1, e0) = exponent `divMod` 10
      copy (digit_table ! e1) ptr
      poke (ptr `plusPtr` 2) (toAscii e0 :: Word8)
      return $ ptr `plusPtr` 3
  | exponent >= 10 = do
      copy (digit_table ! exponent) ptr
      return $ ptr `plusPtr` 2
  | otherwise = do
      poke ptr (toAscii exponent)
      return $ ptr `plusPtr` 1

writeSign :: Ptr Word8 -> Bool -> IO (Ptr Word8)
writeSign ptr True = do
    poke ptr (BS.c2w '-')
    return $ ptr `plusPtr` 1
writeSign ptr False = return ptr

toCharsScientific :: (Mantissa a) => Bool -> a -> Int32 -> BS.ByteString
toCharsScientific sign mantissa exponent = unsafePerformIO $ do
    let olength = decimalLength mantissa
    fp <- BS.mallocByteString 32 :: IO (ForeignPtr Word8)
    withForeignPtr fp $ \p0 -> do
        p1 <- writeSign p0 sign
        p2 <- writeMantissa p1 olength 0 mantissa
        poke p2 (BS.c2w 'E')
        let exp = exponent + fromIntegral olength - 1
            pe = p2 `plusPtr` 1
        end <- if exp < 0
                  then poke pe (BS.c2w '-') >> writeExponent (pe `plusPtr` 1) (-exp)
                  else writeExponent pe exp
        return $ BS.PS fp 0 (end `minusPtr` p0)


--
-- fixed implementation derived from MSVC STL
--

trimmedDigits :: (Mantissa a) => a -> Int32 -> Bool
trimmedDigits mantissa exponent =
    -- Ryu generated X: mantissa * 10^exponent
    -- mantissa == 2^zeros* (mantissa >> zeros)
    -- 10^exponent == 2^exponent * 5^exponent

    -- for float
    -- zeros is [0, 29] (aside: because 2^29 is the largest power of 2
    --                   with 9 decimal digits, which is float's round-trip
    --                   limit.)
    -- exponent is [1, 10].
    -- Normalization adds [2, 23] (aside: at least 2 because the pre-normalized
    --                             mantissa is at least 5).
    -- This adds up to [3, 62], which is well below float's maximum binary
    -- exponent 127
    --
    -- for double
    -- zeros is [0, 56]
    -- exponent is [1, 22].
    -- Normalization adds [2, 52]
    -- This adds up to [3, 130], which is well below double's maximum binary
    -- exponent 1023
    --
    -- In either case, the pow-2 part is entirely encodeable in the exponent bits

    -- Therefore, we just need to consider (mantissa >> zeros) * 5^exponent.

    -- If that product would exceed 24 (53) bits, then X can't be exactly
    -- represented as a float.  (That's not a problem for round-tripping,
    -- because X is close enough to the original float, but X isn't
    -- mathematically equal to the original float.) This requires a
    -- high-precision fallback.
    let zeros = countTrailingZeros mantissa
        shiftMantissa = mantissa .>> zeros
     in shiftMantissa > max_shifted_mantissa `unsafeAt` fromIntegral exponent

writeRightAligned :: (Mantissa a) => Ptr Word8 -> a -> IO ()
writeRightAligned ptr v
  | v >= 10000 = do
      let (v', c) = v `divMod` 10000
          (c1, c0) = c `divMod` 100
      copy (digit_table ! fromIntegral c0) (ptr `plusPtr` (-2))
      copy (digit_table ! fromIntegral c1) (ptr `plusPtr` (-4))
      writeRightAligned (ptr `plusPtr` (-4)) v'
  | v >= 100 = do
      let (v', c) = v `divMod` 100
      copy (digit_table ! fromIntegral c) (ptr `plusPtr` (-2))
      writeRightAligned (ptr `plusPtr` (-2)) v'
  | v >= 10 = do
      copy (digit_table ! fromIntegral v) (ptr `plusPtr` (-2))
  | otherwise = do
      poke (ptr `plusPtr` (-1)) (toAscii v :: Word8)

appendNDigits :: Ptr Word8 -> Word32 -> Int -> IO (Ptr Word8)
appendNDigits ptr w n = do
    let end = ptr `plusPtr` n
    writeRightAligned end w
    return end

-- TODO: handroll hardcoded write?
append9Digits :: Ptr Word8 -> Word32 -> IO (Ptr Word8)
append9Digits ptr w = do
    BS.memset ptr (BS.c2w '0') 9
    appendNDigits ptr w 9

-- exponent| Printed  | wholeDigits | totalLength          | Notes
-- --------|----------|-------------|----------------------|---------------------------------------
--       2 | 172900   |  6          | wholeDigits          | Ryu can't be used for printing
--       1 | 17290    |  5          | (sometimes adjusted) | when the trimmed digits are nonzero.
-- --------|----------|-------------|----------------------|---------------------------------------
--       0 | 1729     |  4          | wholeDigits          | Unified length cases.
-- --------|----------|-------------|----------------------|---------------------------------------
--      -1 | 172.9    |  3          | olength + 1          | This case can't happen for
--      -2 | 17.29    |  2          |                      | olength == 1, but no additional
--      -3 | 1.729    |  1          |                      | code is needed to avoid it.
-- --------|----------|-------------|----------------------|---------------------------------------
--      -4 | 0.1729   |  0          | 2 - exponent         | Print at least one digit before
--      -5 | 0.01729  | -1          |                      | decimal
--      -6 | 0.001729 | -2          |                      |
--
-- returns Nothing when we can't represent through ryu. need to fall back to a
-- higher precision method that is dependent on the original (float / double)
-- input value and type
toCharsFixed :: (Show a, Mantissa a) => Bool -> a -> Int32 -> Maybe BS.ByteString
toCharsFixed sign mantissa exponent = unsafePerformIO $ do
    fp <- BS.mallocByteString 32 :: IO (ForeignPtr Word8)
    let olength = decimalLength mantissa
        wholeDigits = fromIntegral olength + exponent
        totalLength = case () of
                        _ | exponent >= 0   -> wholeDigits
                          | wholeDigits > 0 -> fromIntegral olength + 1
                          | otherwise       -> 2 - exponent
        finalize = Just $ BS.PS fp 0 (fromIntegral totalLength)
    withForeignPtr fp $ \p0 -> do
        p1 <- writeSign p0 sign
        if exponent >= 0
           then
               if exponent > max_representable_pow10 mantissa || trimmedDigits mantissa exponent
                  then return Nothing -- large integer
                  else do
                      -- case 172900 .. 1729
                      let p2 = p1 `plusPtr` olength
                      writeRightAligned p2 mantissa
                      BS.memset p2 (BS.c2w '0') (fromIntegral exponent)
                      return finalize
           else do
               writeRightAligned (p1 `plusPtr` fromIntegral totalLength) mantissa
               if wholeDigits > 0
                  then do
                      -- case 17.29
                      moveBytes p1 (p1 `plusPtr` 1) (fromIntegral wholeDigits)
                      poke (p1 `plusPtr` fromIntegral wholeDigits) (BS.c2w '.')
                      return finalize
                  else do
                      -- case 0.001729
                      BS.memset p1 (BS.c2w '0') (fromIntegral (-wholeDigits) + 2)
                      poke (p1 `plusPtr` 1) (BS.c2w '.')
                      return finalize

toChars :: (Mantissa a) => Bool -> a -> Int32 -> String
toChars s m = BS.unpackChars . toCharsScientific s m


{-# LANGUAGE GeneralizedNewtypeDeriving #-}
-- | Creation of items on the server. Types and operations that don't involve
-- server state nor our custom monads.
module Game.LambdaHack.Server.ItemRev
  ( ItemKnown, ItemRev, UniqueSet, buildItem, newItem
    -- * Item discovery types
  , DiscoveryKindRev, ItemSeedDict, serverDiscos
    -- * The @FlavourMap@ type
  , FlavourMap, emptyFlavourMap, dungeonFlavourMap
  ) where

import Prelude ()

import Game.LambdaHack.Common.Prelude

import           Data.Binary
import qualified Data.EnumMap.Strict as EM
import qualified Data.EnumSet as ES
import qualified Data.HashMap.Strict as HM
import qualified Data.Set as S

import qualified Game.LambdaHack.Common.Color as Color
import           Game.LambdaHack.Common.ContentData
import qualified Game.LambdaHack.Common.Dice as Dice
import           Game.LambdaHack.Common.Flavour
import           Game.LambdaHack.Common.Frequency
import           Game.LambdaHack.Common.Item
import qualified Game.LambdaHack.Common.ItemAspect as IA
import           Game.LambdaHack.Common.Kind
import           Game.LambdaHack.Common.Misc
import           Game.LambdaHack.Common.Random
import           Game.LambdaHack.Common.Time
import           Game.LambdaHack.Content.ItemKind (ItemKind)
import qualified Game.LambdaHack.Content.ItemKind as IK

-- | The essential item properties, used for the @ItemRev@ hash table
-- from items to their ids, needed to assign ids to newly generated items.
-- All the other meaningul properties can be derived from them.
-- Note 1: @jlid@ is not meaningful; it gets forgotten if items from
-- different levels roll the same random properties and so are merged.
-- However, the first item generated by the server wins, which is most
-- of the time the lower @jlid@ item, which makes sense for the client.
-- Note 2: @ItemSeed@ instead of @AspectRecord@ is not enough,
-- becaused different seeds may result in the same @AspectRecord@
-- and we don't want such items to be distinct in UI and elsewhere.
type ItemKnown = (ItemIdentity, IA.AspectRecord, Dice.Dice, Maybe FactionId)

-- | Reverse item map, for item creation, to keep items and item identifiers
-- in bijection.
type ItemRev = HM.HashMap ItemKnown ItemId

type UniqueSet = ES.EnumSet (ContentId ItemKind)

-- | Build an item with the given stats.
buildItem :: COps -> FlavourMap -> DiscoveryKindRev
          -> ContentId ItemKind -> ItemKind -> LevelId -> Dice.Dice
          -> Item
buildItem COps{coitem} (FlavourMap flavourMap) discoRev
          ikChosen kind jlid jdamage =
  let jkind =
        let f :: IK.Feature -> Bool
            f IK.HideAs{} = True
            f _ = False
        in case find f $ IK.ifeature kind of
          Just (IK.HideAs grp) ->
            let kindHidden = ouniqGroup coitem grp
            in IdentityCovered (discoRev EM.! ikChosen) kindHidden
          _ -> IdentityObvious ikChosen
      jfid     = Nothing  -- the default
      jsymbol  = IK.isymbol kind
      jname    = IK.iname kind
      jflavour =
        case IK.iflavour kind of
          [fl] -> fl
          _ -> flavourMap EM.! ikChosen
      jfeature = IK.ifeature kind
      jweight = IK.iweight kind
  in Item{..}

-- | Generate an item based on level.
newItem :: COps -> FlavourMap -> DiscoveryKindRev -> UniqueSet
        -> Freqs ItemKind -> Int -> LevelId -> Dice.AbsDepth -> Dice.AbsDepth
        -> Rnd (Maybe (ItemKnown, ItemFull, IA.ItemSeed, GroupName ItemKind))
newItem cops@COps{coitem} flavourMap discoRev uniqueSet
        itemFreq lvlSpawned lid
        ldepth@(Dice.AbsDepth ldAbs) totalDepth@(Dice.AbsDepth depth) = do
  -- Effective generation depth of actors (not items) increases with spawns.
  let scaledDepth = ldAbs * 10 `div` depth
      numSpawnedCoeff = lvlSpawned `div` 2
      ldSpawned = max ldAbs  -- the first fast spawns are of the nominal level
                  $ min depth
                  $ ldAbs + numSpawnedCoeff - scaledDepth
      findInterval _ x1y1 [] = (x1y1, (11, 0))
      findInterval !ld !x1y1 ((!x, !y) : rest) =
        if fromIntegral ld * 10 <= x * fromIntegral depth
        then (x1y1, (x, y))
        else findInterval ld (x, y) rest
      linearInterpolation !ld !dataset =
        -- We assume @dataset@ is sorted and between 0 and 10.
        let ((x1, y1), (x2, y2)) = findInterval ld (0, 0) dataset
        in ceiling
           $ fromIntegral y1
             + fromIntegral (y2 - y1)
               * (fromIntegral ld * 10 - x1 * fromIntegral depth)
               / ((x2 - x1) * fromIntegral depth)
      f _ _ acc _ ik _ | ik `ES.member` uniqueSet = acc
      f !itemGroup !q !acc !p !ik !kind =
        -- Don't consider lvlSpawned for uniques.
        let ld = if IK.Unique `elem` IK.ieffects kind then ldAbs else ldSpawned
            rarity = linearInterpolation ld (IK.irarity kind)
        in (q * p * rarity, ((ik, kind), itemGroup)) : acc
      g (itemGroup, q) = ofoldlGroup' coitem itemGroup (f itemGroup q) []
      freqDepth = concatMap g itemFreq
      freq = toFreq ("newItem ('" <> tshow ldSpawned <> ")") freqDepth
  if nullFreq freq then return Nothing
  else do
    ((itemKindId, itemKind), itemGroup) <- frequency freq
    -- Number of new items/actors unaffected by number of spawned actors.
    itemN <- castDice ldepth totalDepth (IK.icount itemKind)
    seed <- toEnum <$> random
    jdamage <- frequency $ toFreq "jdamage" $ IK.idamage itemKind
    let itemBase = buildItem cops flavourMap discoRev
                             itemKindId itemKind lid jdamage
        itemIdentity = jkind itemBase
        itemK = max 1 itemN
        itemTimer = [timeZero | IK.Periodic `elem` IK.ieffects itemKind]
                      -- delay first discharge of single organs
        itemSuspect = False
        itemDisco = ItemDiscoFull {..}
        -- Bonuses on items/actors unaffected by number of spawned actors.
        itemAspect =
          IA.seedToAspect seed (IK.iaspects itemKind) ldepth totalDepth
        itemFull = ItemFull {..}
    return $ Just ( (itemIdentity, itemAspect, jdamage, jfid itemBase)
                  , itemFull
                  , seed
                  , itemGroup )

-- | The reverse map to @DiscoveryKind@, needed for item creation.
type DiscoveryKindRev = EM.EnumMap (ContentId ItemKind) ItemKindIx

-- | The map of item ids to item seeds, needed for item creation.
type ItemSeedDict = EM.EnumMap ItemId IA.ItemSeed

serverDiscos :: COps -> Rnd (DiscoveryKind, DiscoveryKindRev)
serverDiscos COps{coitem} = do
  let ixs = [toEnum 0..toEnum (olength coitem - 1)]
      shuffle :: Eq a => [a] -> Rnd [a]
      shuffle [] = return []
      shuffle l = do
        x <- oneOf l
        (x :) <$> shuffle (delete x l)
  shuffled <- shuffle ixs
  let f (!ikMap, !ikRev, ix : rest) kmKind _ =
        (EM.insert ix kmKind ikMap, EM.insert kmKind ix ikRev, rest)
      f (ikMap, _, []) ik  _ =
        error $ "too short ixs" `showFailure` (ik, ikMap)
      (discoS, discoRev, _) =
        ofoldlWithKey' coitem f (EM.empty, EM.empty, shuffled)
  return (discoS, discoRev)

-- | Flavours assigned by the server to item kinds, in this particular game.
newtype FlavourMap = FlavourMap (EM.EnumMap (ContentId ItemKind) Flavour)
  deriving (Show, Binary)

emptyFlavourMap :: FlavourMap
emptyFlavourMap = FlavourMap EM.empty

-- | Assigns flavours to item kinds. Assures no flavor is repeated for the same
-- symbol, except for items with only one permitted flavour.
rollFlavourMap :: S.Set Flavour
               -> Rnd ( EM.EnumMap (ContentId ItemKind) Flavour
                      , EM.EnumMap Char (S.Set Flavour) )
               -> ContentId ItemKind -> ItemKind
               -> Rnd ( EM.EnumMap (ContentId ItemKind) Flavour
                      , EM.EnumMap Char (S.Set Flavour) )
rollFlavourMap fullFlavSet rnd key ik =
  let flavours = IK.iflavour ik
  in if length flavours == 1
     then rnd
     else do
       (!assocs, !availableMap) <- rnd
       let available =
             EM.findWithDefault fullFlavSet (IK.isymbol ik) availableMap
           proper = S.fromList flavours `S.intersection` available
       assert (not (S.null proper)
               `blame` "not enough flavours for items"
               `swith` (flavours, available, ik, availableMap)) $ do
         flavour <- oneOf $ S.toList proper
         let availableReduced = S.delete flavour available
         return ( EM.insert key flavour assocs
                , EM.insert (IK.isymbol ik) availableReduced availableMap)

-- | Randomly chooses flavour for all item kinds for this game.
dungeonFlavourMap :: COps -> Rnd FlavourMap
dungeonFlavourMap COps{coitem} = do
  let allFlav = concatMap (\flv -> map (Flavour flv) Color.stdCol)
                          [minBound..maxBound]
  liftM (FlavourMap . fst) $
    ofoldlWithKey' coitem (rollFlavourMap (S.fromList allFlav))
                          (return (EM.empty, EM.empty))

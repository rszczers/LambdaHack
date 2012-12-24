{-# LANGUAGE ExtendedDefaultRules, OverloadedStrings #-}
{-# OPTIONS_GHC -fno-warn-type-defaults #-}
-- | The game action stuff that is independent from ItemAction.hs
-- (both depend on EffectAction.hs).
-- TODO: Add an export list and document after it's rewritten according to #17.
module Game.LambdaHack.Actions where

-- Cabal
import qualified Paths_LambdaHack as Self (version)

import Control.Monad
import Control.Monad.Writer.Strict (WriterT)
import qualified Data.IntMap as IM
import qualified Data.IntSet as IS
import qualified Data.List as L
import qualified Data.Map as M
import Data.Maybe
import Data.Ratio
import Data.Text (Text)
import qualified Data.Text as T
import Data.Version
import qualified NLP.Miniutter.English as MU

import Game.LambdaHack.Action
import Game.LambdaHack.Actor
import Game.LambdaHack.ActorState
import Game.LambdaHack.Animation (Frames, blockMiss, swapPlaces)
import Game.LambdaHack.Binding
import qualified Game.LambdaHack.Command as Command
import Game.LambdaHack.Config
import Game.LambdaHack.Content.ActorKind
import Game.LambdaHack.Content.ItemKind
import Game.LambdaHack.Content.RuleKind
import Game.LambdaHack.Content.TileKind as TileKind
import Game.LambdaHack.Draw
import qualified Game.LambdaHack.Dungeon as Dungeon
import Game.LambdaHack.DungeonState
import qualified Game.LambdaHack.Effect as Effect
import Game.LambdaHack.EffectAction
import qualified Game.LambdaHack.Feature as F
import Game.LambdaHack.Item
import qualified Game.LambdaHack.Key as K
import qualified Game.LambdaHack.Kind as Kind
import Game.LambdaHack.Level
import Game.LambdaHack.Misc
import Game.LambdaHack.Msg
import Game.LambdaHack.Perception
import Game.LambdaHack.Point
import Game.LambdaHack.Random
import Game.LambdaHack.State
import qualified Game.LambdaHack.Tile as Tile
import Game.LambdaHack.Time
import Game.LambdaHack.Utils.Assert
import Game.LambdaHack.Vector

default (Text)

gameSave :: MonadActionRO m => m ()
gameSave = do
  saveGameBkp
  msgAdd "Game progress saved to a backup file."

gameExit :: MonadAction m => m ()
gameExit = do
  b <- displayYesNo "Really save and exit?"
  if b
    then modifyServer (\ s -> s {squit = Just (True, Camping)})
    else abortWith "Game resumed."

gameRestart :: MonadAction m => m ()
gameRestart = do
  b1 <- displayMore ColorFull "You just requested a new game."
  when (not b1) $ neverMind True
  b2 <- displayYesNo "Current progress will be lost! Really restart the game?"
  when (not b2) $ abortWith "Yea, so much still to do."
  modifyServer (\ s -> s {squit = Just (False, Restart)})

moveCursor :: MonadAction m => Vector -> Int -> WriterT Frames m ()
moveCursor dir n = do
  lxsize <- getsServer (lxsize . slevel)
  lysize <- getsServer (lysize . slevel)
  let upd cursor =
        let shiftB loc =
              shiftBounded lxsize (1, 1, lxsize - 2, lysize - 2) loc dir
            cloc = iterate shiftB (clocation cursor) !! n
        in cursor { clocation = cloc }
  modifyServer (updateCursor upd)
  doLook

ifRunning :: MonadActionPure m => ((Vector, Int) -> m a) -> m a -> m a
ifRunning t e = do
  ad <- getsServer (bdir . getPlayerBody)
  maybe e t ad

-- | Guess and report why the bump command failed.
guessBump :: MonadActionPure m => Kind.Ops TileKind -> F.Feature -> Kind.Id TileKind -> m ()
guessBump cotile F.Openable t | Tile.hasFeature cotile F.Closable t =
  abortWith "already open"
guessBump _ F.Openable _ =
  abortWith "not a door"
guessBump cotile F.Closable t | Tile.hasFeature cotile F.Openable t =
  abortWith "already closed"
guessBump _ F.Closable _ =
  abortWith "not a door"
guessBump cotile F.Ascendable t | Tile.hasFeature cotile F.Descendable t =
  abortWith "the way goes down, not up"
guessBump _ F.Ascendable _ =
  abortWith "no stairs up"
guessBump cotile F.Descendable t | Tile.hasFeature cotile F.Ascendable t =
  abortWith "the way goes up, not down"
guessBump _ F.Descendable _ =
  abortWith "no stairs down"
guessBump _ _ _ = neverMind True

-- | Player tries to trigger a tile using a feature.
bumpTile :: MonadAction m => Point -> F.Feature -> m ()
bumpTile dloc feat = do
  Kind.COps{cotile} <- askCOps
  lvl    <- getsServer slevel
  let t = lvl `at` dloc
  if Tile.hasFeature cotile feat t
    then triggerTile dloc
    else guessBump cotile feat t

-- | Perform the action specified for the tile in case it's triggered.
triggerTile :: MonadAction m => Point -> m ()
triggerTile dloc = do
  Kind.COps{cotile=Kind.Ops{okind, opick}} <- askCOps
  lvl <- getsServer slevel
  let f (F.Cause effect) = do
        pl <- getsServer splayer
        void $ effectToAction effect 0 pl pl 0 False  -- no block against tile
        return ()
      f (F.ChangeTo group) = do
        Level{lactor} <- getsServer slevel
        case lvl `atI` dloc of
          [] -> if unoccupied (IM.elems lactor) dloc
                then do
                  newTileId <- rndToAction $ opick group (const True)
                  let adj = (Kind.// [(dloc, newTileId)])
                  modifyServer (updateLevel (updateLMap adj))
-- TODO: take care of AI using this function (aborts, etc.).
                else abortWith "blocked"  -- by monsters or heroes
          _ : _ -> abortWith "jammed"  -- by items
      f _ = return ()
  mapM_ f $ TileKind.tfeature $ okind $ lvl `at` dloc

-- | Ask for a direction and trigger a tile, if possible.
playerTriggerDir :: MonadAction m => F.Feature -> MU.Part -> m ()
playerTriggerDir feat verb = do
  let keys = zip K.dirAllMoveKey $ repeat K.NoModifier
      prompt = makePhrase ["What to", verb MU.:> "? [movement key"]
  e <- displayChoiceUI prompt [] keys
  lxsize <- getsServer (lxsize . slevel)
  K.handleDir lxsize e (playerBumpDir feat) (neverMind True)

-- | Player tries to trigger a tile in a given direction.
playerBumpDir :: MonadAction m => F.Feature -> Vector -> m ()
playerBumpDir feat dir = do
  pl    <- getsServer splayer
  body  <- getsServer (getActor pl)
  let dloc = bloc body `shift` dir
  bumpTile dloc feat

-- | Player tries to trigger the tile he's standing on.
playerTriggerTile :: MonadAction m => F.Feature -> m ()
playerTriggerTile feat = do
  ploc <- getsServer (bloc . getPlayerBody)
  bumpTile ploc feat

-- | An actor opens a door: player (hero or controlled monster) or enemy.
actorOpenDoor :: MonadAction m => ActorId -> Vector -> m ()
actorOpenDoor actor dir = do
  Kind.COps{ cotile
           , coitem
           , coactor=Kind.Ops{okind}
           } <- askCOps
  lvl  <- getsServer slevel
  pl   <- getsServer splayer
  body <- getsServer (getActor actor)
  bitems <- getsServer (getActorItem actor)
  discoS <- getsServer sdiscoS
  let dloc = shift (bloc body) dir  -- the location we act upon
      t = lvl `at` dloc
      isPlayer = actor == pl
      isVerbose = isPlayer  -- don't report, unless it's player-controlled
      iq = aiq $ okind $ bkind body
      openPower = timeScale timeTurn $
        if isPlayer
        then 0  -- player can't open hidden doors
        else case strongestSearch coitem discoS bitems of
               Just i  -> iq + jpower i
               Nothing -> iq
  unless (openable cotile lvl openPower dloc) $ neverMind isVerbose
  if Tile.hasFeature cotile F.Closable t
    then abortIfWith isVerbose "already open"
    else if not (Tile.hasFeature cotile F.Closable t ||
                 Tile.hasFeature cotile F.Openable t ||
                 Tile.hasFeature cotile F.Hidden t)
         then neverMind isVerbose  -- not doors at all
         else triggerTile dloc

-- | Change the displayed level in targeting mode to (at most)
-- k levels shallower. Enters targeting mode, if not already in one.
tgtAscend :: MonadAction m => Int -> WriterT Frames m ()
tgtAscend k = do
  Kind.COps{cotile} <- askCOps
  cursor    <- getsServer scursor
  targeting <- getsServer (ctargeting . scursor)
  slid      <- getsServer slid
  lvl       <- getsServer slevel
  st        <- getServer
  dungeon   <- getsServer sdungeon
  let loc = clocation cursor
      tile = lvl `at` loc
      rightStairs =
        k ==  1 && Tile.hasFeature cotile (F.Cause Effect.Ascend)  tile ||
        k == -1 && Tile.hasFeature cotile (F.Cause Effect.Descend) tile
  if rightStairs  -- stairs, in the right direction
    then case whereTo st k of
      Nothing ->  -- we are at the "end" of the dungeon
        abortWith "no more levels in this direction"
      Just (nln, nloc) ->
        assert (nln /= slid `blame` (nln, "stairs looped")) $ do
          -- We only look at the level, but we have to keep current
          -- time somewhere, e.g., for when we change the player
          -- to a hero on this level and then end targeting.
          -- If that's too slow, we could keep current time in the @Cursor@.
          switchLevel nln
          -- do not freely reveal the other end of the stairs
          lvl2 <- getsServer slevel
          let upd cur =
                let clocation =
                      if Tile.hasFeature cotile F.Exit (lvl2 `rememberAt` nloc)
                      then nloc  -- already know as an exit, focus on it
                      else loc   -- unknow, do not reveal the position
                in cur { clocation, clocLn = nln }
          modifyServer (updateCursor upd)
    else do  -- no stairs in the right direction
      let n = Dungeon.levelNumber slid
          depth = Dungeon.depth dungeon
          nln = Dungeon.levelDefault $ min depth $ max 1 $ n - k
      when (nln == slid) $ abortWith "no more levels in this direction"
      switchLevel nln  -- see comment above
      let upd cur = cur {clocLn = nln}
      modifyServer (updateCursor upd)
  when (targeting == TgtOff) $ do
    let upd cur = cur {ctargeting = TgtExplicit}
    modifyServer (updateCursor upd)
  doLook

heroesAfterPl :: MonadActionPure m => m [ActorId]
heroesAfterPl = do
  pl <- getsServer splayer
  s  <- getServer
  let hs = map (tryFindHeroK s) [0..9]
      i = fromMaybe (-1) $ L.findIndex (== Just pl) hs
      (lt, gt) = (take i hs, drop (i + 1) hs)
  return $ catMaybes gt ++ catMaybes lt

-- | Switches current hero to the next hero on the level, if any, wrapping.
-- We cycle through at most 10 heroes (\@, 1--9).
cycleHero :: MonadAction m => m ()
cycleHero = do
  pl <- getsServer splayer
  s  <- getServer
  hs <- heroesAfterPl
  case L.filter (flip memActor s) hs of
    [] -> abortWith "Cannot select any other hero on this level."
    ni : _ -> selectPlayer ni
                >>= assert `trueM` (pl, ni, "hero duplicated")

-- | Switches current hero to the previous hero in the whole dungeon,
-- if any, wrapping. We cycle through at most 10 heroes (\@, 1--9).
backCycleHero :: MonadAction m => m ()
backCycleHero = do
  pl <- getsServer splayer
  hs <- heroesAfterPl
  case reverse hs of
    [] -> abortWith "No other hero in the party."
    ni : _ -> selectPlayer ni
                >>= assert `trueM` (pl, ni, "hero duplicated")

-- | Search for hidden doors.
search :: MonadAction m => m ()
search = do
  Kind.COps{coitem, cotile} <- askCOps
  lvl    <- getsServer slevel
  le     <- getsServer (lsecret . slevel)
  lxsize <- getsServer (lxsize . slevel)
  ploc   <- getsServer (bloc . getPlayerBody)
  pitems <- getsServer getPlayerItem
  discoS <- getsServer sdiscoS
  let delta = timeScale timeTurn $
                case strongestSearch coitem discoS pitems of
                  Just i  -> 1 + jpower i
                  Nothing -> 1
      searchTile sle mv =
        let loc = shift ploc mv
            t = lvl `at` loc
            -- TODO: assert or cope elsewhere with the IM.! below
            k = timeAdd (le IM.! loc) $ timeNegate delta
        in if Tile.hasFeature cotile F.Hidden t
           then if k > timeZero
                then IM.insert loc k sle
                else IM.delete loc sle
           else sle
      leNew = L.foldl' searchTile le (moves lxsize)
  modifyServer (updateLevel (\ l -> l {lsecret = leNew}))
  lvlNew <- getsServer slevel
  let triggerHidden mv = do
        let dloc = shift ploc mv
            t = lvlNew `at` dloc
        when (Tile.hasFeature cotile F.Hidden t && IM.notMember dloc leNew) $
          triggerTile dloc
  mapM_ triggerHidden (moves lxsize)

-- | This function performs a move (or attack) by any actor,
-- i.e., it can handle monsters, heroes and both.
moveOrAttack :: MonadAction m
             => Bool       -- ^ allow attacks?
             -> ActorId    -- ^ who's moving?
             -> Vector     -- ^ in which direction?
             -> m ()
moveOrAttack allowAttacks actor dir = do
  -- We start by looking at the target position.
  cops@Kind.COps{cotile = cotile@Kind.Ops{okind}} <- askCOps
  state  <- getServer
  pl     <- getsServer splayer
  lvl    <- getsServer slevel
  sm     <- getsServer (getActor actor)
  let sloc = bloc sm           -- source location
      tloc = sloc `shift` dir  -- target location
  tgt <- getsServer (locToActor tloc)
  case tgt of
    Just target
      | allowAttacks ->
          -- Attacking does not require full access, adjacency is enough.
          actorAttackActor actor target
      | accessible cops lvl sloc tloc -> do
          -- Switching positions requires full access.
          when (actor == pl) $
            msgAdd $ lookAt cops False True state lvl tloc ""
          actorRunActor actor target
      | otherwise -> abortWith "blocked"
    Nothing
      | accessible cops lvl sloc tloc -> do
          -- Perform the move.
          updateAnyActor actor $ \ body -> body {bloc = tloc}
          when (actor == pl) $
            msgAdd $ lookAt cops False True state lvl tloc ""
      | allowAttacks && actor == pl
        && Tile.canBeHidden cotile (okind $ lvl `rememberAt` tloc) -> do
          msgAdd "You search all adjacent walls for half a second."
          search
      | otherwise ->
          actorOpenDoor actor dir  -- try to open a door, TODO: bumpTile tloc F.Openable

-- | Resolves the result of an actor moving into another. Usually this
-- involves melee attack, but with two heroes it just changes focus.
-- Actors on blocked locations can be attacked without any restrictions.
-- For instance, an actor embedded in a wall
-- can be attacked from an adjacent position.
-- This function is analogous to projectGroupItem, but for melee
-- and not using up the weapon.
actorAttackActor :: MonadAction m => ActorId -> ActorId -> m ()
actorAttackActor source target = do
  smRaw <- getsServer (getActor source)
  tmRaw <- getsServer (getActor target)
  per   <- askPerception
  time  <- getsServer stime
  sfaction <- getsServer sfaction
  let sloc = bloc smRaw
      tloc = bloc tmRaw
      svisible = sloc `IS.member` totalVisible per
      tvisible = tloc `IS.member` totalVisible per
      sm | svisible  = smRaw
         | otherwise = smRaw {bname = Just "somebody"}
      tm | tvisible  = tmRaw
         | otherwise = tmRaw {bname = Just "somebody"}
  if bfaction sm == sfaction && not (bproj sm) &&
     bfaction tm == sfaction && not (bproj tm)
    then assert `failure` (source, target, "player AI bumps into friendlies")
    else do
      cops@Kind.COps{coactor, coitem=coitem@Kind.Ops{opick, okind}} <- askCOps
      state <- getServer
      bitems <- getsServer (getActorItem source)
      let h2hGroup = if isAHero state source then "unarmed" else "monstrous"
      h2hKind <- rndToAction $ opick h2hGroup (const True)
      flavour <- getsServer sflavour
      discoRev <- getsServer sdiscoRev
      disco <- getsServer sdisco
      let h2hItem = buildItem flavour discoRev h2hKind (okind h2hKind) 1 0
          (stack, say, verbosity, verb) =
            if isProjectile state source
            then case bitems of
              [bitem] -> (bitem, False, 10, "hit")     -- projectile
              _ -> assert `failure` bitems
            else case strongestSword cops bitems of
              Nothing -> (h2hItem, False, 0,
                          iverbApply $ okind h2hKind)  -- hand to hand combat
              Just w  ->
                let verbApply = case jkind disco w of
                      Nothing -> "hit"
                      Just ik -> iverbApply $ okind ik
                in (w, True, 0, verbApply)
          -- The msg describes the source part of the action.
          -- TODO: right now it also describes the victim and weapon;
          -- perhaps, when a weapon is equipped, just say "you hit"
          -- or "you miss" and then "nose dies" or "nose yells in pain".
          msg = makeSentence $
            [ MU.SubjectVerbSg (partActor coactor sm) verb
            , partActor coactor tm ]
            ++ if say
               then ["with", partItemAW coitem disco stack]
               else []
          msgMiss = makeSentence
            [ MU.SubjectVerbSg (partActor coactor sm) "try to"
            , verb MU.:> ", but"
            , MU.SubjectVerbSg (partActor coactor tm) "block"
            ]
      let performHit block = do
            when (svisible || tvisible) $ msgAdd msg
            -- Msgs inside itemEffectAction describe the target part.
            itemEffectAction verbosity source target stack block
      -- Projectiles can't be blocked, can be sidestepped.
      if braced tm time && not (bproj sm)
        then do
          blocked <- rndToAction $ chance $ 1%2
          if blocked
            then do
              when (svisible || tvisible) $ msgAdd msgMiss
              diary <- getDiary
              let locs = (breturn tvisible tloc,
                          breturn svisible sloc)
                  anim = blockMiss locs
                  animFrs = animate state diary cops per anim
              mapM_ displayFramePush $ Nothing : animFrs
            else performHit True
        else performHit False

-- | Resolves the result of an actor running (not walking) into another.
-- This involves switching positions of the two actors.
actorRunActor :: MonadAction m => ActorId -> ActorId -> m ()
actorRunActor source target = do
  pl <- getsServer splayer
  sm <- getsServer (getActor source)
  tm <- getsServer (getActor target)
  let sloc = bloc sm
      tloc = bloc tm
  updateAnyActor source $ \ m -> m { bloc = tloc }
  updateAnyActor target $ \ m -> m { bloc = sloc }
  cops@Kind.COps{coactor} <- askCOps
  per <- askPerception
  let visible = sloc `IS.member` totalVisible per ||
                tloc `IS.member` totalVisible per
      msg = makeSentence
        [ MU.SubjectVerbSg (partActor coactor sm) "displace"
        , partActor coactor tm ]
  when visible $ msgAdd msg
  diary <- getDiary  -- here diary possibly contains the new msg
  s <- getServer
  let locs = (Just tloc, Just sloc)
      animFrs = animate s diary cops per $ swapPlaces locs
  when visible $ mapM_ displayFramePush $ Nothing : animFrs
  if source == pl
   then stopRunning  -- do not switch positions repeatedly
   else void $ focusIfOurs target

-- | Create a new monster in the level, at a random position.
rollMonster :: Kind.COps -> Perception -> State -> Rnd State
rollMonster Kind.COps{ cotile
                     , coactor=Kind.Ops{opick, okind}
                     , cofact=Kind.Ops{opick=fopick, oname=foname}
                     } per state = do
  let lvl@Level{lactor} = slevel state
      ms = hostileList state
      hs = heroList state
      isLit = Tile.isLit cotile
  rc <- monsterGenChance (Dungeon.levelNumber $ slid state) (L.length ms)
  if not rc
    then return state
    else do
      let distantAtLeast d =
            \ l _ -> L.all (\ h -> chessDist (lxsize lvl) (bloc h) l > d) hs
      loc <-
        findLocTry 20 (lmap lvl)  -- 20 only, for unpredictability
          [ \ _ t -> not (isLit t)
          , distantAtLeast 15
          , \ l t -> not (isLit t) || distantAtLeast 15 l t
          , distantAtLeast 10
          , \ l _ -> not $ l `IS.member` totalVisible per
          , distantAtLeast 5
          , \ l t -> Tile.hasFeature cotile F.Walkable t
                     && unoccupied (IM.elems lactor) l
          ]
      bfaction <- fopick "spawn" (const True)
      mk <- opick (foname bfaction) (const True)
      hp <- rollDice $ ahp $ okind mk
      return $ addMonster cotile mk hp loc bfaction False state

-- | Generate a monster, possibly.
generateMonster :: MonadAction m => m ()
generateMonster = do
  cops    <- askCOps
  state   <- getServer
  per     <- askPerception
  nstate  <- rndToAction $ rollMonster cops per state
  srandom <- getsServer srandom
  putServer $! nstate {srandom}

-- | Possibly regenerate HP for all actors on the current level.
regenerateLevelHP :: MonadAction m => m ()
regenerateLevelHP = do
  Kind.COps{ coitem
           , coactor=coactor@Kind.Ops{okind}
           } <- askCOps
  time <- getsServer stime
  discoS <- getsServer sdiscoS
  let upd itemIM a m =
        let ak = okind $ bkind m
            bitems = fromMaybe [] $ IM.lookup a itemIM
            regen = max 1 $
                      aregen ak `div`
                      case strongestRegen coitem discoS bitems of
                        Just i  -> 5 * jpower i
                        Nothing -> 1
        in if (time `timeFit` timeTurn) `mod` regen /= 0
           then m
           else addHp coactor 1 m
  -- We really want hero selection to be a purely UI distinction,
  -- so all heroes need to regenerate, not just the player.
  -- Only the heroes on the current level regenerate (others are frozen
  -- in time together with their level). This prevents cheating
  -- via sending one hero to a safe level and waiting there.
  hi <- getsServer (linv . slevel)
  modifyServer (updateLevel (updateActorDict (IM.mapWithKey (upd hi))))

-- | Display command help.
displayHelp :: MonadActionRO m => WriterT Frames m ()
displayHelp = do
  keyb <- askBinding
  displaySlideshow "Basic keys." "[press SPACE to advance]" $ keyHelp keyb

-- | Display the main menu.
displayMainMenu :: MonadActionRO m => WriterT Frames m ()
displayMainMenu = do
  Kind.COps{corule} <- askCOps
  Binding{krevMap} <- askBinding
  let stripFrame t = case T.uncons t of
        Just ('\n', art) -> map (T.tail . T.init) $ tail . init $ T.lines art
        _ -> assert `failure` "displayMainMenu:" <+> t
      pasteVersion art =
        let pathsVersion = rpathsVersion $ Kind.stdRuleset corule
            version = " Version " ++ showVersion pathsVersion
                      ++ " (frontend: " ++ frontendName
                      ++ ", engine: LambdaHack " ++ showVersion Self.version
                      ++ ") "
            versionLen = length version
        in init art ++ [take (80 - versionLen) (last art) ++ version]
      kds =  -- key-description pairs
        let showKD cmd key = (showT key, Command.cmdDescription cmd)
            revLookup cmd =
              maybe ("", "") (showKD cmd . fst) $ M.lookup cmd krevMap
            cmds = [Command.GameSave, Command.GameExit,
                   Command.GameRestart, Command.Help]
        in map revLookup cmds ++ [(fst (revLookup Command.Clear), "continue")]
      bindings =  -- key bindings to display
        let bindingLen = 25
            fmt (k, d) =
              let gapLen = (8 - T.length k) `max` 1
                  padLen = bindingLen - T.length k - gapLen - T.length d
              in k <> T.replicate gapLen " " <> d <> T.replicate padLen " "
        in map fmt kds
      overwrite =  -- overwrite the art with key bindings
        let over [] line = ([], T.pack line)
            over bs@(binding : bsRest) line =
              let (prefix, lineRest) = break (=='{') line
                  (braces, suffix)   = span  (=='{') lineRest
              in if length braces == 25
                 then (bsRest, T.pack prefix <> binding <> T.pack suffix)
                 else (bs, T.pack line)
        in snd . L.mapAccumL over bindings
      mainMenuArt = rmainMenuArt $ Kind.stdRuleset corule
      menuOverlay =  -- TODO: switch to Text and use T.justifyLeft
        overwrite $ pasteVersion $ map T.unpack $ stripFrame $ mainMenuArt
  case menuOverlay of
    [] -> assert `failure` "empty Main Menu overlay"
    hd : tl -> displaySlideshow hd "" [tl]

displayHistory :: MonadActionRO m =>  WriterT Frames m ()
displayHistory = do
  Diary{shistory} <- getDiary
  time <- getsServer stime
  lysize <- getsServer (lysize . slevel)
  let turn = time `timeFit` timeTurn
      msg = makeSentence [ "You survived for"
                       , MU.NWs turn "half-second turn" ]
            <+> "Past messages:"
  displaySlideshow msg "" $
    splitOverlay lysize $ renderHistory shistory

dumpConfig :: MonadActionRO m => m ()
dumpConfig = do
  ConfigUI{configRulesCfgFile} <- askConfigUI
  let fn = configRulesCfgFile ++ ".dump"
      msg = "Current game rules configuration dumped to file"
            <+> T.pack fn <> "."
  dumpCfg fn
  abortWith msg

-- | Add new smell traces to the level. Only humans leave a strong scent.
addSmell :: MonadAction m => m ()
addSmell = do
  s  <- getServer
  pl <- getsServer splayer
  let time = stime s
      ploc = bloc (getPlayerBody s)
      upd = IM.insert ploc $ timeAdd time $ smellTimeout s
  when (isAHero s pl) $
    modifyServer $ updateLevel $ updateSmell upd

-- | Update the wait/block count.
setWaitBlock :: MonadAction m => ActorId -> m ()
setWaitBlock actor = do
  Kind.COps{coactor} <- askCOps
  time <- getsServer stime
  updateAnyActor actor $ \ m -> m {bwait = timeAddFromSpeed coactor m time}

-- | Player waits a turn (and blocks, etc.).
waitBlock :: MonadAction m => m ()
waitBlock = do
  pl <- getsServer splayer
  setWaitBlock pl

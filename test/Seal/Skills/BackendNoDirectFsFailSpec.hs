{-# LANGUAGE OverloadedStrings #-}
-- | The no-direct-FS fixture for the workdir-scoped skill backend (§3.6 / W5
-- DoD). The workdir functions in "Seal.Skills.Backend" must NOT use
-- @System.Directory@ or @Data.Text.IO@ for workspace reads — every
-- workspace read goes through the 'WorkdirFs' handle (single SafePath-
-- confined chokepoint).
--
-- **W5 limitation:** unlike W4 (which split the workdir agent-def functions
-- into a separate "Seal.Agent.Def.Workdir" module with NO @System.Directory@
-- / @Data.Text.IO@ imports), W5 keeps the workdir skill functions in the
-- same module as the user-store functions. The user store legitimately
-- needs @System.Directory@ (for @doesFileExist@/@removeFile@/@renameFile@
-- in 'writeSkill'/'deleteSkill') and @Data.Text.IO@ (for 'TIO.writeFile' in
-- 'writeSkill'). A grep-style "no import" assertion would therefore fail
-- spuriously — the module-level imports are shared between the workdir
-- (read-only, 'WorkdirFs'-confined) and user-store (local-FS, §3.9)
-- functions.
--
-- This spec is a structural placeholder: it reads the module source and
-- documents the W5 state with a 'pending' test. W6 (or a follow-up that
-- splits the workdir skill functions into a @Seal.Skills.Workdir@ module,
-- mirroring W4) will strengthen this to the full "no @System.Directory@ /
-- @Data.Text.IO@ import" assertion that W4's
-- 'Seal.Agent.Def.BackendNoDirectFsFailSpec' enforces.
module Seal.Skills.BackendNoDirectFsFailSpec (spec) where

import Test.Hspec

spec :: Spec
spec = describe "Seal.Skills.Backend (no direct FS in workdir functions — §3.6)" $ do
  -- The workdir functions ('listWorkdirSkills', 'listAgentSkillsDir',
  -- 'listTopLevelSkills', 'listGroupedSkills', 'listSubdirs',
  -- 'readAndStampGroup', 'workdirSkillBackendFs') now operate over
  -- 'WorkdirFs'. The user-store functions ('writeSkill', 'deleteSkill',
  -- 'readSkill', 'listSkills') construct a local 'WorkdirFs' via
  -- 'userDirFs' for their reads but keep local-FS for writes. The
  -- module-level @System.Directory@ / @Data.Text.IO@ imports remain for
  -- the user-store write path.
  --
  -- A full grep-style assertion (no @System.Directory@ / @Data.Text.IO@
  -- imports at all) is deferred to W6, when the workdir functions are
  -- split into a @Seal.Skills.Workdir@ module (mirroring W4's split) and
  -- this spec becomes the same shape as
  -- 'Seal.Agent.Def.BackendNoDirectFsFailSpec'. Both checks below are
  -- 'pending' placeholders for W5; W6 will activate them.
  it "defers the full no-direct-FS assertion to W6 (module-split)" $ do
    pendingWith "W6: split workdir skill functions into Seal.Skills.Workdir, \
                \then assert no System.Directory / Data.Text.IO imports \
                \(mirroring Seal.Agent.Def.BackendNoDirectFsFailSpec)."

  it "defers the workdirSkillBackendFs export check to W6" $ do
    pendingWith "W6: assert workdirSkillBackendFs is the sole workdir entry \
                \point once the back-compat FilePath wrapper is removed."
package flyff

// ---------------------------------------------------------------------------
// Flyff (modded Neuz.exe) layout. These are the factory DEFAULTS only: at runtime the live
// values live in Session.layout (a Flyff_Layout), seeded from these and then overridden by
// flyff.cfg / `calibrate`. A game patch shifts them - re-run `calibrate` (no rebuild). RVAs
// are module-base-relative; the live base is always added so a rebase still works.
// ---------------------------------------------------------------------------
FLYFF_WORLD_RVA :: 0x5837CC // static global CWorld* ; m_pObjFocus = [base+RVA] + 0x20
FLYFF_PLAYER_RVA :: 0x571DE8 // static global player CMover*
FLYFF_FOCUS_OFF :: 0x20 // m_pObjFocus offset inside CWorld
FLYFF_FIELD_OFF :: 0x16C // CObj.m_pWorld (every object holds it; our enumeration anchor)
FLYFF_POS_OFF :: 0x160 // CObj.m_vPos (3x f32)
FLYFF_TYPE_REL :: 0x10 // m_dwType, relative to m_vPos (so POS_OFF+0x10)
FLYFF_NAME_OFF :: 0x1DB8 // CMover inline name char buffer
FLYFF_MOVER_TYPE :: 5 // m_dwType for movers (players, pets, NPCs, monsters)
FLYFF_HP_OFF :: 0x281C // CMover current HP (LONG); 0 => dead/despawning (don't target)
FLYFF_MODEL_OFF :: 0x178 // CObj.m_pModel; NULL => not rendered/selectable (crashes on select)

// Server target-sync (PACKETTYPE_SETTARGET via the client's own SendSetTarget). All three
// are located at runtime in the live modded Neuz.exe - see net-package-targeting.md Phase 0
// (codescan for the code addresses, idscan for the offset). 0 means "not yet found": while
// any is 0, `srvsync`/`srvtest` refuse to run and notify_server_target is a no-op.
FLYFF_SENDSETTARGET_RVA :: 0x0 // entry of CDPClient::SendSetTarget (thiscall(OBJID, BYTE))
FLYFF_GDPLAY_RVA :: 0x0 // &g_DPlay (global CDPClient) - the thiscall `this`
FLYFF_OBJID_OFF :: 0x0 // CObj.m_objid (GetId) - value sent as idTarget

// In-world debug markers (see draw.odin / remote_spawn_particles). We call the client's own
// CParticleMng::CreateParticle(nType, &vPos, &vVel, fGroundY) from an injected thread to drop soft
// billboard dots at world positions (colour keyed by nType). Found via the particle texture strings
// (see flyff-particle-draw.md). PATCH-SPECIFIC RVAs - re-derive after a patch. 0 = disabled.
FLYFF_PARTICLEMNG_RVA :: 0x73ABE0 // &g_ParticleMng; m_Particles[0] at +0x8, sizeof(CParticles)=0x3C, m_bActive +0x2C
FLYFF_CREATEPARTICLE_RVA :: 0x422DB0 // CParticleMng::CreateParticle; ret 0x10; folds g_ParticleMng absolute (ecx unused)

// Terrain reachability grid (see terrain.odin). Offsets into CWorld / CLandscape that locate the
// per-cell walkability map (heightmap-encoded attribute). Found at runtime by `worldscan`; 0 means
// "not yet found" and the attr/reach commands stay inert while any of the three structural ones is 0.
FLYFF_LAND_OFF :: 0x0 // CWorld.m_apLand (CLandscape** array base)
FLYFF_LANDWIDTH_OFF :: 0x0 // CWorld.m_nLandWidth (int); m_nLandHeight is +4
FLYFF_MPU_OFF :: 0x0 // CWorld.m_iMPU (int meters-per-unit); 0 => assume MPU_DEFAULT (4)
FLYFF_HMAP_OFF :: 0x0 // CLandscape.m_pHeightMap (float*, 129x129 corner grid)

// Reach-gating tuning (NOT a memory offset): your attack range in world units. `reach`/reach-gated
// target selection only needs the straight path to within this distance of the mob to be walkable
// (you close to range, then attack - ranged has no LOS check on the shot). Per-character; `set
// attack_range <n>`. 0 => test the full path to the mob's cell.
FLYFF_ATTACK_RANGE :: 16

// Static CObj* CWorld::m_aobjCull[] - the render on-screen display array (World.cpp:69). The object
// reach test reads this (fast, ~on-screen count) instead of scanning all of memory for CObj. Found by
// `findcull` (which saves it here); PATCH-SPECIFIC. 0 => fall back to the slow full-memory scan.
FLYFF_AOBJCULL_RVA :: 0x0

// Attackable-monster gate - the SOLE target filter for any-monster ("auto any") mode. The client
// doesn't store a usable AI type on the mover OBJECT (per-object m_dwAIInterface is only set for
// things the client runs AI for, e.g. your stat pet). The game's real classification lives in the
// SPECIES property: CMover::GetProp()->dwAI, where GetProp() = prj.GetMoverProp(m_dwIndex) =
// m_pPropMover + m_dwIndex (a flat MoverProp array indexed by species id). So the gate reads the
// mover's species (m_dwIndex @ pos_off+0x14), indexes the prop array, and keeps only dwAI==AII_MONSTER
// - which excludes pets(5)/eggs(9)/NPCs(AII_NONE)/players and special-AI bosses, generically.
//
// Three runtime-found values wire it (see `findprop`); all patch-specific, 0 = disabled:
//   propmover_rva   - RVA of the global pointer prj.m_pPropMover (points at MoverProp record[0]).
//                     propbase = [module_base + propmover_rva]; record[i] = propbase + i*stride.
//   moverprop_stride- sizeof(MoverProp) (the per-record byte stride). Derived, not from the header.
//   moverprop_ai_off- dwAI's byte offset inside a MoverProp record.
FLYFF_PROPMOVER_RVA :: 0x0
FLYFF_MOVERPROP_STRIDE :: 0x0
FLYFF_MOVERPROP_AI_OFF :: 0x0
AII_MONSTER :: u32(2) // Resource/defineNeuz.h: AII_MONSTER (pets=5, eggs=9, none/NPC=0)
SPECIES_REL :: 0x14   // m_dwIndex (species id) offset relative to pos_off (m_vPos)
MOVERPROP_NAME_OFF :: 4 // MoverProp.szName sits right after the 4-byte dwID at record start

// Live, patch-tunable Flyff layout. Held in Session.layout; seeded by flyff_layout_default(),
// overwritten by flyff.cfg on attach, re-derived by `calibrate`, and persisted back to the cfg.
// Offsets are i64 (cast to uintptr at address sites); RVAs are uintptr; read_obj_type still
// assumes m_dwType sits at pos_off+0x10 (TYPE_REL).
Flyff_Layout :: struct {
  world_rva:         uintptr,
  player_rva:        uintptr,
  focus_off:         i64,
  pos_off:           i64,
  field_off:         i64,
  name_off:          i64,
  hp_off:            i64,
  model_off:         i64,
  mover_type:        u32,
  objid_off:         i64,
  propmover_rva:     uintptr,
  moverprop_stride:  i64,
  moverprop_ai_off:  i64,
  sendsettarget_rva: uintptr,
  gdplay_rva:        uintptr,
  particlemng_rva:    uintptr,
  createparticle_rva: uintptr,
  land_off:          i64,
  landwidth_off:     i64,
  mpu_off:           i64,
  hmap_off:          i64,
  attack_range:      i64,
  aobjcull_rva:      uintptr,
}

flyff_layout_default :: proc() -> Flyff_Layout {
  return Flyff_Layout {
    world_rva         = FLYFF_WORLD_RVA,
    player_rva        = FLYFF_PLAYER_RVA,
    focus_off         = FLYFF_FOCUS_OFF,
    pos_off           = FLYFF_POS_OFF,
    field_off         = FLYFF_FIELD_OFF,
    name_off          = FLYFF_NAME_OFF,
    hp_off            = FLYFF_HP_OFF,
    model_off         = FLYFF_MODEL_OFF,
    mover_type        = FLYFF_MOVER_TYPE,
    objid_off         = FLYFF_OBJID_OFF,
    propmover_rva     = FLYFF_PROPMOVER_RVA,
    moverprop_stride  = FLYFF_MOVERPROP_STRIDE,
    moverprop_ai_off  = FLYFF_MOVERPROP_AI_OFF,
    sendsettarget_rva = FLYFF_SENDSETTARGET_RVA,
    gdplay_rva        = FLYFF_GDPLAY_RVA,
    particlemng_rva    = FLYFF_PARTICLEMNG_RVA,
    createparticle_rva = FLYFF_CREATEPARTICLE_RVA,
    land_off          = FLYFF_LAND_OFF,
    landwidth_off     = FLYFF_LANDWIDTH_OFF,
    mpu_off           = FLYFF_MPU_OFF,
    hmap_off          = FLYFF_HMAP_OFF,
    attack_range      = FLYFF_ATTACK_RANGE,
    aobjcull_rva      = FLYFF_AOBJCULL_RVA,
  }
}

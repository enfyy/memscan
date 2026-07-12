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
FLYFF_ANGLE_OFF :: 0x18 // CObj.m_fAngle (Y-yaw, DEGREES). Obj.cpp: RotationY(-m_fAngle) => forward=(-sin,0,cos)

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
FLYFF_ATTACK_RANGE :: 1.7

// Static CObj* CWorld::m_aobjCull[] - the render on-screen display array (World.cpp:69). The object
// reach test reads this (fast, ~on-screen count) instead of scanning all of memory for CObj. Found by
// `findcull` (which saves it here); PATCH-SPECIFIC. 0 => fall back to the slow full-memory scan.
FLYFF_AOBJCULL_RVA :: 0x0

// Static CCamera* CWorld::m_pCamera (World3D.cpp:34) - the active render camera. m_aobjCull (above) is
// exactly what this camera's frustum draws, so the object-reach check is blind to anything off-camera.
// Found by `findcam`; PATCH-SPECIFIC. Camera layout: vtable +0x0, m_vPos(eye) +0x4, m_vLookAt +0x90.
// Frustum: vFOV pi/4 (45deg) at default zoom, far plane 512, near 0.5 (World3D.cpp). 0 => not found.
FLYFF_CAMERA_RVA :: 0x0

// Collision-mesh filter (see terrain.odin collscan / obj_obb_blocks). The pursuit-movement collision
// (CWorld::ProcessCollision) skips static OT_OBJ props whose model has no dedicated collision mesh
// (m_CollObject.m_Type == GMT_ERROR): those are decorative (bushes, grass, butterflies) that you walk
// through. We reproduce that so decoratives stop marking mobs unreachable. Two build-stable struct
// offsets pin the chain CObj.m_pModel -> m_Element[0].m_pObject3D -> m_CollObject.m_Type; re-pin with
// `collscan` after a patch. 0 => not pinned (filter off; every prop with an OBB blocks, as before).
//   coll_obj3d_off - offset in CModelObject of m_Element[0].m_pObject3D (the collision CObject3D*)
//   coll_type_off  - offset in CObject3D of m_CollObject.m_Type (GMTYPE; GMT_ERROR == -1 == no mesh)
FLYFF_COLL_OBJ3D_OFF :: 0xFC
FLYFF_COLL_TYPE_OFF :: 0x104

// Mesh-accurate reach via the client's own CWorld::IntersectObjLine(pOut,&vPos,&vEnd,bSkipTrans,
// bWithTerrain,bWithObject) - thiscall(ecx=CWorld*), 6 stack args, ret 0x18, BOOL in eax (TRUE=hit).
// Called from an injected thread (remote_intersect_objline) for ground-truth OBB+triangle-mesh line
// tests, replacing our loose whole-OBB approximation for GMT_NORMAL props. PATCH-SPECIFIC RVA; a stale
// value would jump into wrong code = client crash, so remote_intersect_objline verifies the function
// prologue bytes before every call. Re-find after a patch (string "CWorld::IntersectObjLine" ->
// codescan -> func prologue). 0 => disabled.
FLYFF_INTERSECTOBJLINE_RVA :: 0x44AA10

// Camera-INDEPENDENT obstacle source (see terrain.odin collect_area_colliders). Each CLandscape tile
// keeps a flat array of every object on it, unlike m_aobjCull which only holds what the render frustum
// draws (measured: the cull list hides ~47% of nearby colliders). Layout (landscape.h, __MOD_OBJARR):
//   CObj*  m_apObject[MAX_OBJARRAY=8]   @ CLandscape+landobj_off   (index by OT type: OBJ=0, CTRL=3)
//   DWORD  m_adwObjNum[MAX_OBJARRAY=8]  @ CLandscape+landobj_off+0x20  (per-type live count)
// Reach walks the player's tile + neighbours' OBJ/CTRL arrays instead of the cull list. Build-stable
// struct offset; 0 => disabled (reach falls back to the camera-culled cull walk).
FLYFF_LANDOBJ_OFF :: 0x80C
LANDOBJ_MAX_ARRAY :: 8 // MAX_OBJARRAY (ProjectCmn.h); m_adwObjNum follows m_apObject at +MAX_ARRAY*4

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
// Other GetProp()->dwAI classes we reference to colour the radar (players draw as AII_MOVER). We don't
// hard-code the player value: the local player's own species AI is read live and matched, so it stays
// correct across builds. These are only used to sanity-gate that computed value (a player AI must not
// collide with a pet/egg/NPC/monster class). See recon.odin aii_verdict.
AII_NONE :: u32(0) // NPC
AII_MOVER :: u32(1) // player / generic mover
AII_PET :: u32(5)
AII_EGG :: u32(9)
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
  angle_off:         i64,
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
  attack_range:      f32,
  aobjcull_rva:      uintptr,
  camera_rva:        uintptr,
  coll_obj3d_off:    i64,
  coll_type_off:     i64,
  intersectobjline_rva: uintptr,
  landobj_off:       i64,
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
    angle_off         = FLYFF_ANGLE_OFF,
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
    camera_rva        = FLYFF_CAMERA_RVA,
    coll_obj3d_off    = FLYFF_COLL_OBJ3D_OFF,
    coll_type_off     = FLYFF_COLL_TYPE_OFF,
    intersectobjline_rva = FLYFF_INTERSECTOBJLINE_RVA,
    landobj_off       = FLYFF_LANDOBJ_OFF,
  }
}

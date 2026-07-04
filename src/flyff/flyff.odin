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
  sendsettarget_rva: uintptr,
  gdplay_rva:        uintptr,
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
    sendsettarget_rva = FLYFF_SENDSETTARGET_RVA,
    gdplay_rva        = FLYFF_GDPLAY_RVA,
  }
}

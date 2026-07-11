package flyff

import "core:fmt"
import "../engine"

// ============================================================================
// Render camera. m_aobjCull (the object-reach source) is exactly what THIS camera's frustum draws, so
// reach is blind to anything off-camera. Reading the camera lets tdbg draw the cull cone / blind spot.
//
// CCamera layout (Camera.h, verified vs the m_OBB/m_vPos layout): vtable +0x0, m_vPos (eye) +0x4,
// m_matView +0x10, m_matInvView +0x50, m_vLookAt +0x90. The active camera is CWorld::m_pCamera, a static
// global CCamera* at camera_rva (found by `findcam`). Frustum (World3D.cpp): vertical FOV = pi/4 (45deg)
// at default zoom, far plane 512, near 0.5.
// ============================================================================

CAM_POS_OFF :: 0x4 // m_vPos (eye), after the vtable
CAM_LOOKAT_OFF :: 0x90 // m_vLookAt (aim point ~ the player)
FRUSTUM_FAR :: f32(512) // CWorld::m_fFarPlane - the cull far distance
FRUSTUM_VFOV_DEG :: f32(45) // fFov = D3DX_PI/4 at default zoom (vertical); narrows when zoomed
FRUSTUM_HFOV_DEG :: f32(64) // approx horizontal FOV (vFOV 45 at ~16:9); only an estimate - aspect varies

// Read the active camera's eye + look-at via CWorld::m_pCamera (camera_rva). ok=false when not found /
// unconfigured. Read-only.
read_camera :: proc(session: ^Session) -> (eye, lookat: [3]f32, ok: bool) {
  if session.layout.camera_rva == 0 {
    return
  }
  handle := session.proc_info.handle
  pt := session.ptr_size == 4 ? engine.Value_Type.U32 : engine.Value_Type.U64
  cam := read_ptr_at(handle, session.proc_info.base + session.layout.camera_rva, pt)
  if cam < 0x10000 {
    return // the camera object is a global (in-module BSS), so don't require a heap ptr - just non-null
  }
  e, eok := engine.read_vec3(handle, cam + CAM_POS_OFF)
  l, lok := engine.read_vec3(handle, cam + CAM_LOOKAT_OFF)
  if !eok || !lok {
    return
  }
  return e, l, true
}

// findcam - locate the render camera (CWorld::m_pCamera) and save camera_rva. The camera's m_vLookAt sits
// on the player (it aims at you), so we scan for a vec3 ~ the player position, treat each hit as
// m_vLookAt, and keep the one whose object has a module vtable and an ELEVATED eye (m_vPos) a sensible
// camera-distance away (3rd-person behind + above). Then find the static global pointing at it. Read-only
// except the cfg write.
cli_findcam :: proc(session: ^Session, args: []string) {
  if !session.attached {
    fmt.eprintln("not attached.")
    return
  }
  handle := session.proc_info.handle
  base := session.proc_info.base
  size := session.proc_info.module_size
  mod_end := base + uintptr(size)
  ps := session.ptr_size
  pt := ps == 4 ? engine.Value_Type.U32 : engine.Value_Type.U64

  ppos, pok := read_player_pos(session)
  if !pok {
    fmt.eprintln("couldn't read player position - run 'calibrate' first.")
    return
  }

  // The camera aims at the player, so m_vLookAt ~ player pos (a few units of lag).
  cands := engine.scan_vec3(handle, ppos, 4.0, context.temp_allocator)
  cam: uintptr = 0
  eye, lookat: [3]f32
  for c in cands {
    obj := c - CAM_LOOKAT_OFF
    if uintptr(CAM_LOOKAT_OFF) > c {
      continue
    }
    vt := read_ptr_at(handle, obj, pt)
    if vt < base || vt >= mod_end {
      continue // camera has a vtable; this hit isn't a CCamera
    }
    la, laok := engine.read_vec3(handle, c)
    ey, eyok := engine.read_vec3(handle, obj + CAM_POS_OFF)
    if !laok || !eyok {
      continue
    }
    dh := engine.dist_horizontal(ey, la)
    dy := ey[1] - la[1]
    // 3rd-person: eye is a camera-distance behind (a few..~80 units) and above the aim point.
    if dh >= 1.5 && dh <= 120 && dy > 0.3 {
      cam = obj
      eye = ey
      lookat = la
      break
    }
  }
  if cam == 0 {
    fmt.eprintln("findcam: no camera found (m_vLookAt ~ player with an elevated eye). Are you fully in-game?")
    return
  }

  // The static global CWorld::m_pCamera holds this object's pointer.
  hits := engine.scan_image_for_ptr(handle, base, size, cam, ps, context.temp_allocator)
  if len(hits) == 0 {
    fmt.eprintfln("findcam: found the camera obj=0x%X but no static pointer to it in the image.", cam)
    return
  }
  session.layout.camera_rva = hits[0] - base

  fwd := [3]f32{lookat[0] - eye[0], lookat[1] - eye[1], lookat[2] - eye[2]}
  fmt.printfln("findcam: camera_rva=0x%X  obj=0x%X", session.layout.camera_rva, cam)
  fmt.printfln("  eye=(%.1f, %.1f, %.1f)  lookAt=(%.1f, %.1f, %.1f)", eye[0], eye[1], eye[2], lookat[0], lookat[1], lookat[2])
  fmt.printfln(
    "  horiz dist %.1f, %.1f above aim; heading (%.2f, %.2f). frustum: vFOV~45deg, far 512.",
    engine.dist_horizontal(eye, lookat),
    eye[1] - lookat[1],
    fwd[0],
    fwd[2],
  )
  if flyff_save_cfg(session.layout, flyff_cfg_path()) {
    fmt.println("  saved to flyff.cfg.")
  }
}

package flyff

import "core:fmt"
import "core:strings"

import imgui "../../lib/odin-imgui"

// ===========================================================================
// The typed string field: one text box, a suggestion list under it, and - for a list-valued argument
// - badges you can remove.
//
// WHY IT IS NOT A COMBO. Every one of these fields has to keep taking free text, and not as a
// courtesy: `key_down @dir` is the whole reason variables exist, a private server's mob is not in any
// wiki dump, and a chart written for a variable that a later node sets cannot be picked from a list
// that does not know about it yet. So the value is always a text box; the corpus only SUGGESTS.
//
// WHY THE SUGGESTIONS ARE INLINE AND NOT A POPUP. Two reasons, one of them load-bearing:
//
//   - An ImGui popup takes keyboard focus when it opens, which deactivates the text field under it,
//     which closes the popup. Type-ahead and BeginPopup want opposite things. The existing
//     browse-style popups here (gui_ed_palette, gui_ed_find) dodge that by putting the search box
//     INSIDE the popup - fine when you are looking something up, one click too many when you are
//     filling in a field you are already typing in.
//   - gui_nodes.odin:1805 documents the other half: a popup's id is seeded from the current window's
//     id stack, so OpenPopup and BeginPopup have to run in the same window. ed_params is called from
//     two different ones (the inspector sidebar and the options form). Drawing rows inline has no id
//     stack to get wrong.
//
// This is also what the pre-ImGui panel did, and it is what "the old input with badges" refers to.
//
// THE ONE PIECE OF STATE. `Gui_Editor.suggest_field` is the hash of the field whose list is open -
// one at a time, and a hash rather than a string because the options panel draws every node at once
// and the id is rebuilt per frame. It LATCHES on the text box going active and is cleared when the
// box goes inactive with nothing in the list hovered. That ordering matters: on the frame you click a
// suggestion the box is already inactive, so testing "is the box active" alone would take the list
// away half a frame before the click landed on it.
// ===========================================================================

SUGGEST_LIMIT :: 8 // rows offered at once. A list you have to scroll is not a suggestion.

// FNV-1a over the field id. The id is a per-frame ctprintf, so it cannot be stored; the hash can.
suggest_id_hash :: proc(id: cstring) -> u32 {
	h := u32(2166136261)
	for c in string(id) {
		h = (h ~ u32(c)) * 16777619
	}
	return h == 0 ? 1 : h // 0 means "nothing open"
}

// ImGui InputText character filter callback to block semicolons from being typed or pasted.
@(private = "file")
block_semicolon_filter :: proc "c" (data: ^imgui.InputTextCallbackData) -> i32 {
	if data.EventChar == ';' {
		return 1 // Drop character
	}
	return 0
}

// The names a field of this kind offers for the text typed so far. `exclude` is what is already
// chosen (badges), so a list argument never suggests something it already holds.
suggest_corpus :: proc(
	kind: Param_Kind,
	choices: []string,
	query: string,
	exclude: []string,
	f: ^Gui_Frame,
	doc: ^Behaviour_Doc,
) -> []string {
	switch kind {
	case .Mob, .Names:
		return mob_suggestions(query, f.nearby_names, exclude, SUGGEST_LIMIT)
	case .Key:
		return suggest_filter(key_name_choices(), query, exclude)
	case .Choice:
		return suggest_filter(choices, query, exclude)
	case .Var_Name:
		return suggest_filter(chart_variable_names(doc), query, exclude)
	case .Chart_Name:
		// Derived from what is on disk right now, like .Var_Name is derived from the open document. The
		// registry is scanned on the browser's throttle rather than here - this runs per frame while a
		// field is open, and a directory listing per frame is exactly what that cache exists to avoid.
		return suggest_filter(subchart_registry_names(), query, exclude)
	case .Str, .Num, .Duration, .Percent, .Coord:
		return nil
	}
	return nil
}

// Case-insensitive substring filter, capped. Names that START with the query come first: typing "e"
// for a key should offer "end" and "enter" before "delete".
suggest_filter :: proc(corpus: []string, query: string, exclude: []string, allocator := context.temp_allocator) -> []string {
	needle := strings.to_lower(strings.trim_space(query), context.temp_allocator)
	out := make([dynamic]string, 0, SUGGEST_LIMIT, allocator)
	for leading in ([?]bool{true, false}) {
		for candidate in corpus {
			if len(out) >= SUGGEST_LIMIT {
				return out[:]
			}
			lower := strings.to_lower(candidate, context.temp_allocator)
			if needle != "" {
				if !strings.contains(lower, needle) {
					continue
				}
				if strings.has_prefix(lower, needle) != leading {
					continue
				}
			} else if !leading {
				continue // no query: one pass over the whole corpus, in its own order
			}
			if name_list_contains(exclude, candidate) || name_list_contains(out[:], candidate) {
				continue
			}
			append(&out, candidate)
		}
	}
	return out[:]
}

// --- the offered rows, held still while you aim at them ---------------------------------------------
//
// A suggestion list has to be STABLE between the frame the mouse goes down on a row and the frame it
// comes up, or ImGui has no item to pair the press with and the click is silently dropped. Half the mob
// corpus is `Gui_Frame.nearby_names`, rebuilt by the radar every frame out of the live blips, so it
// reorders whenever a monster dies, respawns or walks out of range - and because live names are offered
// FIRST, one arriving shifts every row under it. That is the "some names I can't turn into badges" bug:
// nothing was wrong with those names, they were just the rows the churn happened to move.
//
// So the rows are computed once and held, and only these three things rebuild them - each one something
// the user did, none of them the world moving:
//   - a different field opened its list,
//   - the text in the box changed,
//   - a badge was added or removed (a chosen name has to leave the list, and one removed comes back).

@(private = "file")
ed_suggest_rows_rebuild :: proc(ed: ^Gui_Editor, rows: []string, query: string, badges: int) {
	ed_suggest_rows_clear(ed)
	for r in rows {
		append(&ed.suggest_rows, strings.clone(r))
	}
	delete(ed.suggest_for_query)
	ed.suggest_for_query = strings.clone(query)
	ed.suggest_for_badges = badges
}

// Not file-private: gui_editor_free calls it, and the rows outlive any one panel.
ed_suggest_rows_clear :: proc(ed: ^Gui_Editor) {
	for r in ed.suggest_rows {
		delete(r)
	}
	clear(&ed.suggest_rows)
	delete(ed.suggest_for_query)
	ed.suggest_for_query = ""
	ed.suggest_for_badges = -1 // no badge count can match, so the next open always rebuilds
}

// --- editing a semicolon-joined name list -----------------------------------------------------------
//
// LIFETIME, and it is the whole reason these are procs rather than four lines at the call site.
// `parse_target_names` hands back SLICES INTO the list string - `strings.split` does not copy - so the
// new value has to be BUILT BEFORE the old one is freed. Written the obvious way round, delete then
// join, both badge paths read freed memory and what came back depended on what the allocator had done
// with the hole. That is what "the badges are bugged" was: a long name in a list was enough to make the
// reuse visible, and a short one usually was not.
//
// Both return a fresh allocation; the caller frees the old string AFTER taking it.

// <list> plus <name>, appended.
name_list_add :: proc(list: string, name: string, allocator := context.allocator) -> string {
	parts := parse_target_names(list)
	out := make([dynamic]string, 0, len(parts) + 1, context.temp_allocator)
	append(&out, ..parts[:])
	append(&out, name)
	return strings.join(out[:], "; ", allocator)
}

// <list> without the entry at <index>. An index outside the list gives the list back unchanged.
name_list_remove :: proc(list: string, index: int, allocator := context.allocator) -> string {
	parts := parse_target_names(list)
	out := make([dynamic]string, 0, len(parts), context.temp_allocator)
	for p, i in parts {
		if i != index {
			append(&out, p)
		}
	}
	return strings.join(out[:], "; ", allocator)
}

// Proves the two above keep every name intact, including the ones that made this worth having: a
// species whose name carries digits and spaces ("2nd Class Fefern") survives being added next to
// others and having a neighbour removed.
//
// It does NOT prove the lifetime - a use-after-free is not reliably observable from inside the process,
// and reading a freed string may well give the right answer. That half is guarded by construction: the
// only paths that edit a list go through these, and these allocate before anything is freed.
name_list_selftest :: proc() {
	fmt.println("  --- name lists ---")
	fails := 0
	check :: proc(what: string, got, want: string, fails: ^int) {
		if got != want {
			fmt.eprintfln("  FAIL: %s: got '%s', wanted '%s'", what, got, want)
			fails^ += 1
		}
	}
	tricky :: "2nd Class Fefern"

	a := name_list_add("", tricky)
	defer delete(a)
	check("adding to an empty list", a, tricky, &fails)

	b := name_list_add(a, "Aibatt")
	defer delete(b)
	check("adding a second", b, "2nd Class Fefern; Aibatt", &fails)

	c := name_list_add(b, "Captain Catsy")
	defer delete(c)
	check("adding a third", c, "2nd Class Fefern; Aibatt; Captain Catsy", &fails)

	d := name_list_remove(c, 1)
	defer delete(d)
	check("removing the middle one", d, "2nd Class Fefern; Captain Catsy", &fails)

	e := name_list_remove(d, 0)
	defer delete(e)
	check("removing the digit-leading one", e, "Captain Catsy", &fails)

	f := name_list_remove(e, 0)
	defer delete(f)
	check("removing the last one", f, "", &fails)

	// Quoted input is what a .bhv holds for a name with spaces; the badges must not grow quote marks.
	g := name_list_add("'Mutant Giant 2nd Class Fefern'", "Yetti")
	defer delete(g)
	check("a quoted name is unwrapped once", g, "Mutant Giant 2nd Class Fefern; Yetti", &fails)

	h := name_list_remove(a, 7)
	defer delete(h)
	check("an out-of-range remove changes nothing", h, tricky, &fails)

	if fails == 0 {
		fmt.println("  PASS: names with digits, spaces and quotes survive being added and removed")
	}
}

// One string argument. Returns true when `value` changed.
//
// In SINGLE mode the text buffer holds the value itself. In LIST mode (.Names) it holds the search
// text and the value is the semicolon-joined badge list - which is why a list argument is no longer
// capped by the buffer: what you type is bounded, what you accumulate is not.
// `corpus_override`, when given, replaces whatever the kind would have offered. One caller uses it:
// a Coord's expression field, whose corpus is this chart's variables spelled as @name - the kind
// there is a position, not a name, so there is nothing for suggest_corpus to key off.
ed_suggest_field :: proc(
	ed: ^Gui_Editor,
	id: cstring,
	label: cstring,
	value: ^string,
	buffer: []u8,
	kind: Param_Kind,
	choices: []string,
	hint: cstring,
	width: f32,
	f: ^Gui_Frame,
	corpus_override: []string = nil,
) -> (changed: bool) {
	hash := suggest_id_hash(id)
	multi := kind == .Names
	badges: []string
	if multi {
		parsed := parse_target_names(value^)
		badges = parsed[:]
	}

	// --- the text box -------------------------------------------------------------------------------
	imgui.SetNextItemWidth(width)
	typed := imgui.InputTextWithHint(
		label,
		hint,
		cstring(raw_data(buffer)),
		len(buffer),
		{.CallbackCharFilter},
		block_semicolon_filter,
	)
	active := imgui.IsItemActive()
	if active && ed.suggest_field != hash {
		ed.suggest_field = hash
		ed_suggest_rows_clear(ed) // a different field's rows are not this one's
	}
	if typed && !multi {
		delete(value^)
		value^ = strings.clone(panel_buf_str(buffer))
		changed = true
	}
	query := panel_buf_str(buffer)

	// --- badges -------------------------------------------------------------------------------------
	// Drawn between the box and the list: they are the VALUE, so they stay put, where the suggestions
	// come and go under them.
	if multi && len(badges) > 0 {
		avail := imgui.GetContentRegionAvail().x
		used := f32(0)
		for name, i in badges {
			button_w := imgui.CalcTextSize(fmt.ctprintf("%s  x", name)).x + imgui.GetStyle().FramePadding.x * 2
			if i > 0 && used + px(4) + button_w < avail {
				imgui.SameLine(0, px(4))
				used += px(4) + button_w
			} else {
				used = button_w
			}
			if imgui.SmallButton(fmt.ctprintf("%s  x##%sbadge%d", name, id, i)) {
				ed_snapshot(ed)
				next := name_list_remove(value^, i) // built first - `badges` points into value^
				delete(value^)
				value^ = next
				changed = true
			}
			if imgui.IsItemHovered() {
				imgui.SetTooltip("Remove %s", fmt.ctprintf("%s", name))
			}
		}
	}

	// --- the suggestion list ------------------------------------------------------------------------
	if ed.suggest_field != hash {
		return changed
	}
	// Held, not recomputed - see ed_suggest_rows_rebuild for what a per-frame list did to the clicks.
	if ed.suggest_for_query != query || ed.suggest_for_badges != len(badges) {
		fresh := corpus_override != nil \
		? suggest_filter(corpus_override, query, badges) \
		: suggest_corpus(kind, choices, query, badges, f, &ed.doc)
		ed_suggest_rows_rebuild(ed, fresh, query, len(badges))
	}
	rows := ed.suggest_rows[:]
	hovered_any := false
	picked := ""
	for name in rows {
		if imgui.Selectable(fmt.ctprintf("%s##%ssug%s", name, id, name)) {
			picked = name
		}
		if imgui.IsItemHovered() {
			hovered_any = true
		}
	}
	// A list argument can always take the text as typed, even when nothing matched - that is how a mob
	// this build has never seen gets added. A single-valued field needs no such row: the text box IS
	// the value there, so it is already added.
	if multi && strings.trim_space(query) != "" && !name_list_contains(badges, strings.trim_space(query)) {
		if imgui.Selectable(fmt.ctprintf("add \"%s\"##%sadd", strings.trim_space(query), id)) {
			picked = strings.trim_space(query)
		}
		if imgui.IsItemHovered() {
			hovered_any = true
		}
	}
	if picked != "" {
		ed_snapshot(ed)
		if multi {
			next := name_list_add(value^, picked) // built first - `badges` points into value^
			delete(value^)
			value^ = next
			buffer[0] = 0 // clear the search box, the way picking a chip used to
		} else {
			delete(value^)
			value^ = strings.clone(picked)
			copy_into_buffer(buffer, picked)
			// `picked` has been copied out by both lines above, so the rows it points into can go.
			ed.suggest_field = 0 // one value, one pick - there is nothing left to choose
			ed_suggest_rows_clear(ed)
		}
		changed = true
	} else if !active && !hovered_any && ed.suggest_field == hash {
		// Left the field without touching the list.
		ed.suggest_field = 0
		ed_suggest_rows_clear(ed)
	}
	return changed
}

// Overwrite a fixed text buffer with <text>, truncated and NUL-terminated. The editor's buffers are
// C strings handed straight to ImGui, so the terminator is not optional.
copy_into_buffer :: proc(buffer: []u8, text: string) {
	n := min(len(text), len(buffer) - 1)
	copy(buffer[:n], text[:n])
	buffer[n] = 0
}
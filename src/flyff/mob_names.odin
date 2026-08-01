package flyff

import "base:runtime"
import "core:strings"

// ===========================================================================
// The monster-name corpus the node editor suggests from.
//
// A `.Names` or `.Mob` argument is matched against the game's own species name, exactly, so the one
// thing an author needs is the spelling - which is precisely what a bare text box cannot give them.
// This list is the offline half of that; the live half is Gui_Frame.nearby_names, which the radar
// snapshot fills from whatever is actually on screen. They are merged and deduped at the widget.
//
// It is a CONVENIENCE, never a constraint: a name that is not listed can still be typed, and must be
// - a private server's custom mob is not going to be in a wiki dump.
//
// Sourced from the Flyff wiki's "Complete Monster list" (flyff.fandom.com/wiki/Complete_Monster_list).
// Regenerate from there on updates. Restored verbatim from the pre-ImGui radar panel (219cbf1
// src/flyff/radar.odin); it was lost in the GUI migration along with the chips that used it.
// ===========================================================================

@(rodata)
MOB_NAME_CORPUS := [?]string {
  "(Anguished Soul) Mara", "(Deathbringer) Kheldor", "(Demonic Soul) Hel", "(General) Razgul", "(God of Death) Ankou", "(Perverted Soul) Morrigan",
  "(Tormented Soul) Nergal", "(Twisted Soul) Orcus", "(Violent Soul) Ghed", "Abraxas", "Aibatt", "Air Marshall Spiketail",
  "Ant Turtle", "Antiquery", "Araknoid", "Arc Master of the Violet Magician Troupe", "Asmodan", "Asterius",
  "Asuras", "Atrox", "Augu", "Axe-Jaw Ant", "Babari", "Bang",
  "Basque", "Battle Toadrin", "Bearnerky", "Beast King Khan", "Beast Overlord Khan", "Big Muscle",
  "Blackweb Shade", "Blighted Gryphon", "Blood Trillipy", "Bloody Mary", "Blue Meteonyker", "Blue Roach",
  "Blue Roach Queen", "Boo", "Boss Cardpuppet", "Brigadier General Crumple", "Bucrow", "Burudeng",
  "Cannibal Mammoth", "Cardpuppet", "Carrierbomb", "Catsy", "Chaner", "Chef Muffrin",
  "Chief Keokuk", "Chimeradon", "Clocks", "Clockworks", "Clockworks Butler", "Club-tailed Reptilion",
  "Colonel Club-tailed Reptilion", "Crane Machinery", "Creper", "Cursed Axe-Jaw Ant", "Cursed Giant Maul Rat", "Cursed Giant Scorpede",
  "Cursed Maul Rat", "Cursed Razor Axe-Jaw Ant", "Cursed Scorpede", "Cyclops X", "Dantalian", "Demian",
  "Dire Razor", "Dorian", "Doridoma", "Drakul the Diabolic", "Dread Drakul the Diabolic", "Dread Lykanos the Malevolent",
  "Dreadful Rangda", "Driller", "Dumb Bull", "Dump", "Elderguard", "Elite Keakoon Guard",
  "Elite Keakoon Guard Leader", "Elite Keakoon Worker", "Elite Keakoon Worker Leader", "Elite Tanuki Enforcer", "Elite Tanuki Protector", "Emeraldmantis",
  "Fallen Necromancer", "Fefern", "Female Zombie", "Flbyrigen", "Flybat", "Forsaken Banshee",
  "GM Cromiell", "Gangard", "Gannessa", "Garbagepider", "General Bearnerky", "General Chimeradon",
  "General Glyphaxz", "Ghost of the Forgotten King", "Ghost of the Forgotten Prince", "Giant Abraxas", "Giant Aibatt", "Giant Antiquery",
  "Giant Araknoid", "Giant Asterius", "Giant Asuras", "Giant Bang", "Giant Basque", "Giant Battle Toadrin",
  "Giant Boo", "Giant Bucrow", "Giant Burudeng", "Giant Carrierbomb", "Giant Catsy", "Giant Crane Machinery",
  "Giant Dantalian", "Giant Demian", "Giant Doridoma", "Giant Driller", "Giant Dumb Bull", "Giant Dump",
  "Giant Elderguard", "Giant Fefern", "Giant Flbyrigen", "Giant Flybat", "Giant Gannessa", "Giant Garbagepider",
  "Giant Giggle Box", "Giant Glaphan", "Giant Gongury", "Giant Greemong", "Giant Grrr", "Giant Gullah",
  "Giant Hague", "Giant Harpy", "Giant Hobo", "Giant Hoppre", "Giant Iren", "Giant Jack The Hammer",
  "Giant Kern", "Giant Lawolf", "Giant Leyena", "Giant Luia", "Giant Maul Rat", "Giant Mia",
  "Giant Mothbee", "Giant Mr Pumpkin", "Giant Mushpang", "Giant Mushpoie", "Giant Nautrepy", "Giant Nuctuvehicle",
  "Giant Nutty Wheel", "Giant Nyangnyang", "Giant Peakyturtle", "Giant Pukepuke", "Giant Red Mantis", "Giant Risem",
  "Giant Rock Muscle", "Giant Rockepeller", "Giant Scorpede", "Giant Scorpicon", "Giant Shuhamma", "Giant Steamwalker",
  "Giant Steel Knight", "Giant Syliaca", "Giant Tengu", "Giant Tombstone Bearer", "Giant Totemia", "Giant Trangfoma",
  "Giant Volt", "Giant Wagsaac", "Giant Watangka", "Giant Wheelem", "Giant Zombiger", "Giantmage Prankster",
  "Giggle Box", "Glaphan", "Gobbler", "Gongury", "Great Abraxas", "Great Asterius",
  "Great Asuras", "Great Catsy", "Great Chef Muffrin", "Great Dantalian", "Great Gannessa", "Great Gullah",
  "Great Hague", "Great Harpy", "Great Tengu", "Great White Bolo", "Greemong", "Green Meteonyker",
  "Green Trillipy", "Grrr", "Grumble Mauler", "Guan Yu Heavyblade", "Gullah", "Hadeseor",
  "Hague", "Hammer Kick", "Harpy", "Hazard Blood Trillipy", "Hazard Green Trillipy", "Hazard Violet Trillipy",
  "Hellhound", "Hobo", "Hoiren", "Hoppre", "Horrible Rangda", "Hundur Sharpfoot",
  "Hunter X", "Idol of Blighted Gryphon", "Idol of Fallen Necromancer", "Idol of Forsaken Banshee", "Idol of Scythe Protector", "Idol of Vile Flayer",
  "Immovable Crag", "Iren", "Ivillis Black Otem", "Ivillis Boxter", "Ivillis Crasher", "Ivillis Dandysher",
  "Ivillis Destroyer", "Ivillis Guardian", "Ivillis Leanes", "Ivillis Mushellizer", "Ivillis Poisoner", "Ivillis Puppet",
  "Ivillis Quaker", "Ivillis Red Otem", "Ivillis Thief", "Ivillis Wrecker", "Jack The Hammer", "Kanonicus",
  "Keakoon Guard", "Keakoon Guard Leader", "Keakoon Worker", "Keakoon Worker Leader", "Kern", "Kidler",
  "Kingster", "Kraken", "Krrr", "Kynsy", "Kyouchish", "Lawolf",
  "Leyena", "Lieutenant General Scythoid", "Lord Bang", "Lord Bang Hanoyan", "Lord Clockworks Alpha", "Luia",
  "Lykanos the Malevolent", "Mage Redcloud", "Male Zombie", "Mammoth", "Master Demian", "Master Muffrin",
  "Maul Rat", "Meral", "Meteonyker", "Mia", "Mocomochi", "Monument of Death",
  "Mothbee", "Mr Pumpkin", "Mushmoot", "Mushpang", "Mushpoie", "Mutant Augu",
  "Mutant Bang", "Mutant Fefern", "Mutant Giant 2nd Class Fefern", "Mutant Giant Bang King", "Mutant Giant Nyangnyang", "Mutant Keakoon Guard",
  "Mutant Keakoon Guard Leader", "Mutant Keakoon Worker", "Mutant Keakoon Worker Leader", "Mutant Nyangnyang", "Mutant Yetti", "Mythic Prismatic Cobra",
  "Mythic Twinstrike Cobra", "Mythic Wildwood Stalker", "Naga", "Nautrepy", "Nuctuvehicle", "Nutty Wheel",
  "Nyangnyang", "Nyx", "Okean", "Organigor", "Peakyturtle", "Pink Roach",
  "Pink Roach Queen", "Popcrank", "Prankster", "Prismatic Cobra", "Pukepuke", "Queen Popcrank",
  "R. DeFeo", "Rampaging Dumb Bull", "Rangda", "Razor Axe-Jaw Ant", "Red Bang", "Red Mantis",
  "Red Meteonyker", "Ren", "Risem", "Risen Assassin", "Risen Gladiator", "Risen Mage",
  "Risen Pikeman", "Risen Warrior", "Rock Muscle", "Rockepeller", "Rubo", "Sakai",
  "Samoset", "Scorpede", "Scorpicon", "Scythe Protector", "Seido", "Serus Uriel",
  "Shacalpion", "Shadowy Wildwood Shaman", "Shuhamma", "Shuraiture", "Sisif", "Small Mushpoie",
  "Spotted Bolo", "Steamwalker", "Steel Knight", "Syliaca", "Taiaha", "Tanuki Enforcer",
  "Tanuki Protector", "Tengu", "Tombstone Bearer", "Totem", "Totemia", "Trangfoma",
  "Troglodon Warlord", "Troglodon Warrior", "Twinstrike Cobra", "Uncanny Rangda", "Venel Guardian", "Vice Veduque",
  "Vile Flayer", "Vile Thorn", "Violet Magician Troupe", "Violet Trillipy", "Volt", "Wagsaac",
  "Watangka", "Wheelem", "Wildwood Shaman", "Wildwood Stalker", "Worm Veduque", "Yetti",
  "Zombiger", "Mortom", "Captain Catsy", "Captain Harpy",
  "Water Totem pole", "Wind Totem pole", "Earth Totem pole", "Fire Totem pole",
  "Hanya, the avenger", "Lilieth, legendary thief", "Lord of Nightmare"
}

// Case-insensitive membership. Used to keep a name that is already a badge out of the suggestions,
// and to dedupe the wiki list against the live one.
name_list_contains :: proc(list: []string, name: string) -> bool {
  for n in list {
    if strings.equal_fold(n, name) {
      return true
    }
  }
  return false
}

// "Captain" and "Small" are variant MODIFIERS, not species. Typing one has to keep the whole base
// list visible - otherwise "Captain" narrows to the four Captains that happen to be spelled out in
// the corpus - so a leading modifier is stripped off the query here and prepended onto whatever you
// pick. Anything after it still narrows the base list.
mob_filter_split :: proc(query: string) -> (prefix: string, rest: string) {
  lower := strings.to_lower(strings.trim_space(query), context.temp_allocator)
  trimmed := strings.trim_space(query)
  for modifier in ([?]string{"Captain", "Small"}) {
    low_modifier := strings.to_lower(modifier, context.temp_allocator)
    if lower == low_modifier || strings.has_prefix(lower, strings.concatenate({low_modifier, " "}, context.temp_allocator)) {
      return modifier, strings.trim_space(trimmed[len(modifier):])
    }
  }
  return "", trimmed
}

// The names to offer for <query>: the wiki corpus plus whatever is on screen, filtered by substring,
// composed with any modifier prefix, minus what is already chosen. Capped, because a popup listing
// four hundred rows is a wall, not a suggestion.
mob_suggestions :: proc(query: string, live: []string, exclude: []string, limit: int, allocator := context.temp_allocator) -> []string {
  out := make([dynamic]string, 0, limit, allocator)
  prefix, rest := mob_filter_split(query)
  needle := strings.to_lower(rest, context.temp_allocator)
  prefix_with_space := ""
  if prefix != "" {
    prefix_with_space = strings.to_lower(strings.concatenate({prefix, " "}, context.temp_allocator), context.temp_allocator)
  }
  consider :: proc(
    candidate, needle, prefix, prefix_with_space: string,
    exclude: []string,
    out: ^[dynamic]string,
    limit: int,
    allocator: runtime.Allocator,
  ) {
    if len(out) >= limit {
      return
    }
    if needle != "" && !strings.contains(strings.to_lower(candidate, context.temp_allocator), needle) {
      return
    }
    full := candidate
    // Don't double up: "Captain Catsy" is already in the corpus, and "Captain Captain Catsy" is not
    // a monster.
    if prefix != "" && !strings.has_prefix(strings.to_lower(candidate, context.temp_allocator), prefix_with_space) {
      full = strings.concatenate({prefix, " ", candidate}, allocator)
    }
    if name_list_contains(exclude, full) || name_list_contains(out[:], full) {
      return
    }
    append(out, full)
  }
  // Live names first: what is in front of you is a better guess than what a wiki page lists.
  for n in live {
    consider(n, needle, prefix, prefix_with_space, exclude, &out, limit, allocator)
  }
  for n in MOB_NAME_CORPUS {
    consider(n, needle, prefix, prefix_with_space, exclude, &out, limit, allocator)
  }
  return out[:]
}

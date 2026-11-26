import Std

/- NEdit-style Editor, rewritten in Lean. Tcl/Tk supplies native widgets only.
   No Python code or Python runtime is used by this program. -/
@[extern "editor_tk_init"] opaque tkInit (gui : Bool) : IO Unit
@[extern "editor_is_main_thread"] opaque isMainThread : IO Bool
@[extern "editor_startup_configured"] opaque startupConfigured : IO Bool
@[extern "editor_tk_call"] opaque tk (args : @& Array String) : IO String
@[extern "editor_tk_eval"] opaque tkEval (script : @& String) : IO String
@[extern "editor_tk_words"] opaque words (value : @& String) : IO (Array String)
@[extern "editor_tk_loop"] opaque tkLoop : IO Unit
@[extern "editor_atomic_write"] opaque atomicWrite (path : @& String) (data : @& ByteArray) : IO Unit
@[extern "editor_is_word"] opaque isWordChar (codepoint : UInt32) : Bool

def cmd (args : Array String) : IO Unit := do discard <| tk args
def script (value : String) : IO Unit := do discard <| tkEval value
def trim (s : String) : String := s.trimAscii.toString
def spaces (n : Nat) : String := String.ofList (List.replicate n ' ')
def join (xs : List String) (sep := "\n") : String := String.intercalate sep xs
def truth (s : String) : Bool := s == "1" || s == "true"
/- Platform differences are chosen at compile time for the native target. -/
def onMac : Bool := System.Platform.isOSX
/-- Preferred editor fonts on X11, first installed wins. Tk does not apply
    fontconfig's alias preferences, so "Monospace" alone can resolve to a
    Courier clone (e.g. Nimbus Mono PS) even when better faces exist. -/
def x11MonoFamilies : List String :=
  ["Adwaita Mono","DejaVu Sans Mono","Noto Sans Mono","Liberation Mono","Ubuntu Mono","Cascadia Mono"]
initialize monoFamilyCache : IO.Ref (Option String) ← IO.mkRef none
def monoFamily : IO String := do
  if onMac then return "Menlo"
  if let some family := (← monoFamilyCache.get) then return family
  let installed ← words (← tk #["font","families"])
  let family := (x11MonoFamilies.find? installed.contains).getD "Monospace"
  monoFamilyCache.set (some family)
  return family
/-- Tk font description; the family is braced so multi-word names parse. -/
def monoFont (size : Nat) : IO String := return "{" ++ (← monoFamily) ++ "} " ++ toString size
/-- Read the clipboard or a selection. X11 Tk defaults to the legacy Latin-1
    STRING target, which garbles non-ASCII text copied from Wayland/GTK/Qt
    apps; request UTF8_STRING first and fall back for owners without it. -/
def selectionGet (args : Array String) : IO String := do
  if onMac then return ← tk args
  try tk (args ++ #["-type","UTF8_STRING"]) catch _ => tk args
/-- Modifiers that trigger editor shortcuts. Tk's Command modifier is the
    macOS Command key only on aqua; on X11 it is an unrelated modifier bit. -/
def shortcutModifiers : List String := if onMac then ["Control","Command"] else ["Control"]
def accelLabel (label : String) : String := if onMac then label else label.replace "Cmd" "Ctrl"
def number (s : String) : Nat := s.toNat?.getD 0
def charSlice (s : String) (a b : Nat) : String := String.ofList ((s.toList.drop a).take (b-a))
def leading (s : String) : String := String.ofList (s.toList.takeWhile (fun c => c == ' ' || c == '\t'))

structure Document where
  path : String := ""
  text : String := ""
  original : Option ByteArray := none
  newline : String := "\n"
  bom : Bool := false
  deriving Inhabited

def readOptional (path : String) : IO (Option ByteArray) := do
  try return some (← IO.FS.readBinFile path)
  catch e => match e with
    | .noFileOrDirectory .. => return none
    | _ => throw e

def canonical (path : String) : IO String := do
  let p ← tk #["file","normalize",path]
  if ← (System.FilePath.mk p).pathExists then return (← IO.FS.realPath p).toString
  let parent := (System.FilePath.mk p).parent.getD "."
  return ((← IO.FS.realPath parent) / (System.FilePath.mk p).fileName.getD "untitled.txt").toString

def decodeDocument (path : String) (raw : Option ByteArray) : IO Document := do
  match raw with
  | none => return {path}
  | some bytes =>
    let bom := bytes.size ≥ 3 && bytes[0]! == 239 && bytes[1]! == 187 && bytes[2]! == 191
    let content := if bom then bytes.extract 3 bytes.size else bytes
    let some value := String.fromUTF8? content | throw <| IO.userError "This file is not valid UTF-8. Nothing was changed."
    let chars := value.toList
    let rest := chars.dropWhile (fun c => c != '\r' && c != '\n')
    let newline := match rest with
      | '\r' :: '\n' :: _ => "\r\n"
      | '\r' :: _ => "\r"
      | _ => "\n"
    return {path,original:=raw,bom,newline,text:=value.replace "\r\n" "\n" |>.replace "\r" "\n"}

def openDocument (path : String) : IO Document := do
  let path ← canonical path
  decodeDocument path (← readOptional path)

def encodeDocument (doc : Document) (text : String) : ByteArray :=
  if text == doc.text then doc.original.getD text.toUTF8
  else ((if doc.bom then "\uFEFF" else "") ++ text.replace "\n" doc.newline).toUTF8

def saveDocument (doc : Document) (text path : String) (overwrite := false) : IO Document := do
  let path ← canonical path
  let existing ← readOptional path
  let expected := if path == doc.path then doc.original else none
  if !overwrite && existing != expected then throw <| IO.userError "CONFLICT: file changed on disk or destination already exists."
  let bytes := encodeDocument doc text
  atomicWrite path bytes
  return {doc with path,text,original:=some bytes}

def delimiter (text : String) (offset : Nat) : Option Nat := Id.run do
  let a := text.toList.toArray
  if offset ≥ a.size then return none
  let c := a[offset]!
  if ['"','\'','`','/','\\'].contains c then
    for i in [offset+1:a.size] do
      if a[i]! == c then return some i
    return none
  let pairs := [('(',')'),('[',']'),('{','}'),('<','>')]
  let pair := pairs.find? (fun p => p.1 == c || p.2 == c)
  let some (left,right) := pair | return none
  let forward := c == left
  let other := if forward then right else left
  let indices := if forward then (List.range (a.size-offset-1)).map (·+offset+1) else (List.range offset).reverse
  let mut depth := 1
  for i in indices do
    if a[i]! == c then depth := depth+1
    if a[i]! == other then
      depth := depth-1
      if depth == 0 then return some i
  return none

def wordBoundary (text : String) (offset : Nat) (forward := false) : Nat := Id.run do
  let chars := text.toList.toArray
  let isWord := fun c : Char => isWordChar c.val
  let mut i := min offset chars.size
  if forward then
    while i < chars.size && isWord chars[i]! do i := i+1
    while i < chars.size && !isWord chars[i]! do i := i+1
  else
    while i > 0 && !isWord chars[i-1]! do i := i-1
    while i > 0 && isWord chars[i-1]! do i := i-1
  return i

def indentText (s : String) (amount : Int) : String :=
  join <| (s.splitOn "\n").map fun line =>
    if amount > 0 then spaces amount.toNat ++ line
    else if line.startsWith "\t" then charSlice line 1 line.length
    else charSlice line (min amount.natAbs (line.toList.takeWhile (· == ' ')).length) line.length

def fillText (s : String) : String := Id.run do
  let indent := leading s
  let paragraphs := s.splitOn "\n\n"
  let mut output := []
  for p in paragraphs do
    let ws := (p.splitOn "\n" |>.flatMap (·.splitOn " ") |>.flatMap (·.splitOn "\t")).filter (· != "")
    let mut lines := []
    let mut current := indent
    for word in ws do
      if current != indent && current.length+word.length+1 > 80 then
        lines := lines ++ [current]; current := indent
      current := current ++ (if current == indent then "" else " ") ++ word
    lines := lines ++ [current]
    output := output ++ [join lines]
  return join output "\n\n"

abbrev RunningChild := IO.Process.Child {stdin:=.null,stdout:=.piped,stderr:=.piped}
structure ShellJob where
  child : RunningChild
  task : Task (Except IO.Error IO.Process.Output)
  before : String
  ranges : Array (String × String)
  filter : Bool
  inline : Bool

structure Window where
  id : String
  pane : String
  panes : Array String
  doc : Document := {}
  seen : Option ByteArray := none
  unavailable : Bool := false
  font : Nat := 13
  overtype : Bool := false
  anchor : String := ""
  query : String := ""
  replacement : String := ""
  incrementalOrigin : String := "1.0"
  recording : Bool := false
  replaying : Bool := false
  recorded : Array (Array String) := #[]
  lastAction : Array String := #[]
  repeatLeft : Nat := 0
  busy : Bool := false
  job : Option ShellJob := none
  deriving Inhabited

initialize windows : IO.Ref (Array Window) ← IO.mkRef #[]
initialize serial : IO.Ref Nat ← IO.mkRef 0
initialize previous : IO.Ref String ← IO.mkRef ""
initialize active : IO.Ref String ← IO.mkRef ""
def getWindow (id : String) : IO Window := do
  let some w := (← windows.get).find? (·.id == id) | throw <| IO.userError "Window was closed."
  return w
def change (id : String) (f : Window → Window) : IO Unit := windows.modify (·.map (fun w => if w.id == id then f w else w))
def widgetExists (path : String) : IO Bool := return truth (← tk #["winfo","exists",path])
def textCall (id : String) (args : Array String) : IO String := do tk (#[ (← getWindow id).pane ] ++ args)
def textCmd (id : String) (args : Array String) : IO Unit := do discard <| textCall id args
def contents (id : String) : IO String := textCall id #["get","1.0","end-1c"]
def dirty (id : String) : IO Bool := return (← contents id) != (← getWindow id).doc.text
def actionScript (id : String) (args : Array String) : IO String := tk (#["list","editor",id] ++ args)
def bindAction (widget key id : String) (args : Array String) (stop := true) : IO Unit := do
  cmd #["bind",widget,key,(← actionScript id args) ++ if stop then "; break" else ""]
def feedback (id msg : String) : IO Unit := cmd #["set",id++"_feedback",msg]
def message (id title body : String) (kind := "ok") : IO String :=
  tk #["tk_messageBox","-parent",id,"-title",title,"-message",body,"-type",kind]
def alert (id title body : String) : IO Unit := do discard <| message id title body
def updateStatus (id : String) : IO Unit := do
  let w ← getWindow id
  let name := if w.doc.path == "" then "Untitled" else w.doc.path
  cmd #["wm","title",id,(if ← dirty id then "* " else "") ++ name ++ " — EditorLean"]
  let index := (← textCall id #["index","insert"]).splitOn "."
  let mode := if w.recording then "Recording" else if w.overtype then "Overtype" else "Insert"
  cmd #[id++".status","configure","-text",s!"Line {index[0]!}, Column {number index[1]!+1}    |    {mode}    |    UTF-8    |    {name}"]

def ranges (id : String) : IO (Array (String × String)) := do
  let mut values ← words (← textCall id #["tag","ranges","rectsel"])
  if values.isEmpty then values ← words (← textCall id #["tag","ranges","sel"])
  return ((List.range (values.size/2)).map fun i => (values[2*i]!,values[2*i+1]!)).toArray
def selected (id : String) : IO String := do
  let mut result := []
  for (a,b) in ← ranges id do result := result ++ [← textCall id #["get",a,b]]
  return join result
def deselect (id : String) : IO Unit := do
  for tag in #["sel","rectsel"] do textCmd id #["tag","remove",tag,"1.0","end"]
  change id fun w => {w with anchor:=""}
def insertText (id value : String) : IO Unit := do
  let rs ← ranges id
  let rectangular := (← textCall id #["tag","ranges","rectsel"]) != ""
  textCmd id #["edit","separator"]
  if rectangular then
    for (a,b) in rs.reverse do textCmd id #["replace",a,b,value]
  else
    if !rs.isEmpty then
      textCmd id #["mark","set","insert",rs[0]!.1]
      textCmd id #["delete",rs[0]!.1,rs[0]!.2]
    else if (← getWindow id).overtype && !(value.contains '\n') then
      let finish ← textCall id #["index",s!"insert+{value.length}c"]
      let finish ← if truth (← textCall id #["compare",finish,">","insert lineend"]) then textCall id #["index","insert lineend"] else pure finish
      textCmd id #["delete","insert",finish]
    textCmd id #["insert","insert",value]
  deselect id
  textCmd id #["see","insert"]

def install (id : String) (doc : Document) : IO Unit := do
  change id fun w => {w with doc,seen:=doc.original,unavailable:=false}
  textCmd id #["delete","1.0","end"]
  textCmd id #["insert","1.0",doc.text]
  textCmd id #["edit","reset"]
  textCmd id #["edit","modified","0"]
  deselect id
  for mark in ← words (← textCall id #["mark","names"]) do
    if mark.startsWith "bookmark_" then textCmd id #["mark","unset",mark]
  textCmd id #["mark","set","insert","1.0"]
  cmd #["focus",(← getWindow id).pane]
  updateStatus id

def ask (id title prompt initial : String) : IO (Option String) := do
  let dialog := id++".prompt"
  if ← widgetExists dialog then cmd #["destroy",dialog]
  cmd #["toplevel",dialog]; cmd #["wm","title",dialog,title]; cmd #["wm","transient",dialog,id]
  cmd #["label",dialog++".label","-text",prompt]; cmd #["pack",dialog++".label","-padx","20","-pady","10"]
  cmd #["entry",dialog++".entry","-width","50","-exportselection","0"]
  cmd #[dialog++".entry","insert","0",initial]; cmd #[dialog++".entry","selection","range","0","end"]
  cmd #["pack",dialog++".entry","-padx","20","-pady","8"]
  cmd #["set",id++"_answer",""]; cmd #["set",id++"_accepted","0"]
  let accept := s!"set {id}_answer [{dialog}.entry get]; set {id}_accepted 1; destroy {dialog}"
  cmd #["button",dialog++".ok","-text","OK","-command",accept]; cmd #["pack",dialog++".ok","-pady","8"]
  cmd #["bind",dialog,"<Return>",accept]; cmd #["bind",dialog,"<Escape>","destroy "++dialog]
  cmd #["grab","set",dialog]; cmd #["focus",dialog++".entry"]; cmd #["tkwait","window",dialog]
  if truth (← tk #["set",id++"_accepted"]) then return some (← tk #["set",id++"_answer"])
  return none

def save (id : String) (saveAs := false) : IO Bool := do
  let w ← getWindow id
  let mut path := w.doc.path
  if saveAs || path == "" then
    path ← tk #["tk_getSaveFile","-parent",id,"-initialfile",if path == "" then "untitled.txt" else (System.FilePath.mk path).fileName.getD "untitled.txt","-confirmoverwrite","0"]
  if path == "" then return false
  let text ← contents id
  let doc ← try saveDocument w.doc text path
    catch e =>
      if (toString e).contains 'C' && (toString e).startsWith "CONFLICT:" then
        if (← message id "File already exists or changed" "The destination exists or changed on disk. Overwrite it?" "yesno") == "yes" then saveDocument w.doc text path true
        else return false
      else throw e
  change id fun current => {current with doc,seen:=doc.original,unavailable:=false}
  updateStatus id
  return true

def confirmDiscard (id : String) : IO Bool := do
  if !(← dirty id) then return true
  match ← message id "Unsaved changes" "Save your changes first?" "yesnocancel" with
  | "yes" => save id
  | "no" => return true
  | _ => return false

def reload (id : String) (manual := true) : IO Unit := do
  let w ← getWindow id
  if w.doc.path == "" then return
  if manual && (← dirty id) && (← message id "Revert" "Discard unsaved changes and reload?" "yesno") != "yes" then return
  let doc ← openDocument w.doc.path
  if doc.original.isNone then throw <| IO.userError "File no longer exists. Your open text has been kept."
  let cursor ← textCall id #["index","insert"]
  let scroll ← words (← textCall id #["yview"])
  install id doc
  textCmd id #["mark","set","insert",cursor]
  textCmd id #["yview","moveto",scroll[0]!]

def focusPane (id pane : String) : IO Unit := do
  if !(← getWindow id).panes.contains pane then return
  if (← active.get) != id then previous.set (← active.get); active.set id
  change id fun w => {w with pane}
  cmd #[id++".frame.v","configure","-command",← tk #["list",pane,"yview"]]
  cmd #[id++".frame.h","configure","-command",← tk #["list",pane,"xview"]]
  cmd #[pane,"configure","-yscrollcommand",id++".frame.v set","-xscrollcommand",id++".frame.h set"]

def clipboard (id op : String) : IO Unit := do
  if op == "paste" then insertText id (← selectionGet #["clipboard","get"])
  else
    let value ← selected id
    if value != "" then
      cmd #["clipboard","clear"]; cmd #["clipboard","append","--",value]
      if op == "cut" then insertText id ""

def pasteColumn (id value : String) : IO Unit := do
  let rc := (← textCall id #["index","insert"]).splitOn "."
  let row := number rc[0]!
  let col := number rc[1]!
  textCmd id #["edit","separator"]
  for (line,offset) in (value.splitOn "\n").zipIdx do
    let target := row+offset
    while number ((← textCall id #["index","end-1c"]).splitOn ".")[0]! < target do textCmd id #["insert","end-1c","\n"]
    let len := number ((← textCall id #["index",s!"{target}.end"]).splitOn ".")[1]!
    if len < col then textCmd id #["insert",s!"{target}.end",spaces (col-len)]
    textCmd id #["insert",s!"{target}.{col}",line]
  textCmd id #["edit","separator"]

def selectTo (id target : String) (rect := false) : IO Unit := do
  let w ← getWindow id
  let anchor ← if w.anchor == "" then textCall id #["index","insert"] else pure w.anchor
  deselect id
  change id fun current => {current with anchor}
  if rect then
    let a := anchor.splitOn "."; let b := target.splitOn "."
    for row in [min (number a[0]!) (number b[0]!):max (number a[0]!) (number b[0]!)+1] do
      textCmd id #["tag","add","rectsel",s!"{row}.{min (number a[1]!) (number b[1]!)}",s!"{row}.{max (number a[1]!) (number b[1]!)}"]
  else
    let forwards := truth (← textCall id #["compare",anchor,"<",target])
    textCmd id #["tag","add","sel",if forwards then anchor else target,if forwards then target else anchor]
  textCmd id #["mark","set","insert",target]; textCmd id #["see",target]

def search (id : String) (backwards := false) : IO Unit := do
  let w ← getWindow id
  let q ← if ← widgetExists (id++".find") then tk #["set",id++"_query"] else pure w.query
  let r ← if ← widgetExists (id++".find") then tk #["set",id++"_replacement"] else pure w.replacement
  change id fun c => {c with query:=q,replacement:=r}
  if q == "" then feedback id "Enter text to find."; return
  let rs ← ranges id
  let origin := if backwards && !rs.isEmpty then rs[0]!.1 else "insert"
  let args := #["search","-exact","-count",id++"_length"] ++ (if backwards then #["-backwards"] else #[]) ++ #["--",q]
  let mut first ← textCall id (args ++ #[origin,if backwards then "1.0" else "end"])
  if first == "" then first ← textCall id (args ++ #[if backwards then "end-1c" else "1.0",origin])
  if first == "" then feedback id "No match found (case sensitive)."; cmd #["bell"]; return
  let count ← tk #["set",id++"_length"]
  let last ← textCall id #["index",first++"+"++count++"c"]
  deselect id
  textCmd id #["tag","add","sel",first,last]
  textCmd id #["mark","set","insert",last]; textCmd id #["see",first]
  let rc := first.splitOn "."
  feedback id s!"Found at line {rc[0]!}, column {number rc[1]!+1}."

def findDialog (id : String) (backwards := false) (replaceMode := false) : IO Unit := do
  let w ← getWindow id
  let p := id++".find"
  if ← widgetExists p then cmd #["destroy",p]
  cmd #["toplevel",p]; cmd #["wm","title",p,"Find / Replace"]; cmd #["wm","transient",p,id]
  cmd #["wm","protocol",p,"WM_DELETE_WINDOW",← actionScript id #["closefind"]]
  cmd #["set",id++"_query",w.query]; cmd #["set",id++"_replacement",w.replacement]; feedback id ""
  for (name,caption,varName,row) in [("query","Find (case sensitive)","_query","0"),("replacement","Replace with","_replacement","1")] do
    cmd #["label",p++".l"++name,"-text",caption]; cmd #["grid",p++".l"++name,"-row",row,"-column","0","-padx","8","-pady","6"]
    cmd #["entry",p++"."++name,"-width","35","-textvariable",id++varName,"-exportselection","0"]
    cmd #["grid",p++"."++name,"-row",row,"-column","1","-padx","8","-pady","6"]
  cmd #["frame",p++".buttons"]; cmd #["grid",p++".buttons","-row","2","-columnspan","2","-pady","8"]
  for (key,caption,action) in [("next","Find Next","find"),("replace","Replace","replace"),("all","Replace All","replaceall"),("close","Close","closefind")] do
    cmd #["button",p++".buttons."++key,"-text",caption,"-command",← actionScript id #[action,if backwards then "1" else "0"]]
    cmd #["pack",p++".buttons."++key,"-side","left","-padx","4"]
  cmd #["label",p++".feedback","-textvariable",id++"_feedback","-anchor","w"]
  cmd #["grid",p++".feedback","-row","3","-columnspan","2","-sticky","ew","-padx","8","-pady","6"]
  bindAction p "<Return>" id #[if replaceMode then "replace" else "find",if backwards then "1" else "0"]
  bindAction p "<Escape>" id #["closefind"]
  for modifier in shortcutModifiers do
    bindAction p s!"<{modifier}-w>" id #["closefind"]
    bindAction p s!"<{modifier}-g>" id #["find","0"]
    bindAction p s!"<{modifier}-Shift-G>" id #["find","1"]
  cmd #[p++".query","selection","range","0","end"]
  cmd #["after","idle",← tk #["list","focus",p++".query"]]

def replaceMatches (id : String) (all := false) (backwards := false) : IO Unit := do
  if ← widgetExists (id++".find") then
    let q ← tk #["set",id++"_query"]; let r ← tk #["set",id++"_replacement"]
    change id fun w => {w with query:=q,replacement:=r}
  let w ← getWindow id
  if w.query == "" then feedback id "Enter text to find."; return
  let mut hits : Array (String × String) := #[]
  if all then
    let mut cursor := "1.0"
    repeat
      let first ← textCall id #["search","-exact","-count",id++"_length","--",w.query,cursor,"end"]
      if first == "" then break
      let count ← tk #["set",id++"_length"]
      cursor ← textCall id #["index",first++"+"++count++"c"]
      hits := hits.push (first,cursor)
  else if (← selected id) == w.query then hits ← ranges id
  textCmd id #["edit","separator"]; textCmd id #["configure","-autoseparators","0"]
  try for (a,b) in hits.reverse do textCmd id #["replace",a,b,w.replacement]
  finally textCmd id #["configure","-autoseparators","1"]; textCmd id #["edit","separator"]
  if all then feedback id s!"Replaced {hits.size} occurrence(s)." else search id backwards

def moveCursor (id key : String) (control shift rect : Bool) : IO Unit := do
  let cursor ← textCall id #["index","insert"]
  let row := number (cursor.splitOn ".")[0]!
  let mut target := cursor
  if control && (key == "Left" || key == "Right") then
    let offset := (← textCall id #["get","1.0","insert"]).length
    target := s!"1.0+{wordBoundary (← contents id) offset (key == "Right")}c"
  else if control && (key == "Up" || key == "Down") then
    let last := number ((← textCall id #["index","end-1c"]).splitOn ".")[0]!
    let mut next := if key == "Up" then row-1 else row+1
    while next > 1 && next < last && trim (← textCall id #["get",s!"{next}.0",s!"{next}.end"]) != "" do
      next := if key == "Up" then next-1 else next+1
    target := s!"{max 1 (min last next)}.0"
  else if key == "Prior" || key == "Next" then
    let sign := if key == "Prior" then "-" else "+"
    let direction := if key == "Prior" then "-1" else "1"
    if control then
      textCmd id #["xview","scroll",direction,"pages"]
      target := "insert"++sign++"60c"
    else
      let height ← tk #["winfo","height",(← getWindow id).pane]
      let top := number ((← textCall id #["index","@0,0"]).splitOn ".")[0]!
      let bottom := number ((← textCall id #["index","@0,"++height]).splitOn ".")[0]!
      target := "insert"++sign++toString (max 1 (bottom-top-1))++" display lines"
      textCmd id #["yview","scroll",direction,"pages"]
  else
    target := match key with
      | "Left" => "insert-1c" | "Right" => "insert+1c"
      | "Home" => if control then "1.0" else "insert linestart"
      | "End" => if control then "end-1c" else "insert lineend"
      | "Up" => "insert-1 display lines" | "Down" => "insert+1 display lines"
      | _ => cursor
  target ← textCall id #["index",target]
  if truth (← textCall id #["compare",target,">","end-1c"]) then target ← textCall id #["index","end-1c"]
  if shift then selectTo id target rect else
    deselect id; textCmd id #["mark","set","insert",target]; textCmd id #["see",target]

def deleteSpan (id mode : String) : IO Unit := do
  if !(← ranges id).isEmpty then insertText id ""; return
  textCmd id #["edit","separator"]
  match mode with
  | "back" => textCmd id #["delete","insert-1c","insert"]
  | "forward" => textCmd id #["delete","insert","insert+1c"]
  | "start" => textCmd id #["delete","insert linestart","insert"]
  | "end" => textCmd id #["delete","insert","insert lineend"]
  | "word" =>
    let offset := (← textCall id #["get","1.0","insert"]).length
    textCmd id #["delete",s!"1.0+{wordBoundary (← contents id) offset}c","insert"]
  | _ => pure ()

def transform (id action : String) (arg := "") : IO Unit := do
  let rs ← ranges id
  if action == "change_case" then
    let rs ← if rs.isEmpty then pure #[(← textCall id #["index","insert"],← textCall id #["index","insert+1c"])] else pure rs
    textCmd id #["edit","separator"]
    for (first,last) in rs.reverse do
      let value ← textCall id #["get",first,last]
      let value ← tk #["string",if truth arg then "tolower" else "toupper",value]
      textCmd id #["replace",first,last,value]
    textCmd id #["edit","separator"]
    return
  let mut first := if rs.isEmpty then "insert linestart" else rs[0]!.1
  let mut last := if rs.isEmpty then "insert lineend" else rs[rs.size-1]!.2
  if action == "shift_indent" then
    first ← textCall id #["index",first++" linestart"]
    if !rs.isEmpty && (last.splitOn ".")[1]! == "0" then last ← textCall id #["index",last++"-1c"]
    last ← textCall id #["index",last++" lineend"]
  if action == "fill_paragraph" && rs.isEmpty then
    let lines := (← contents id).splitOn "\n" |>.toArray
    let mut row := number ((← textCall id #["index","insert"]).splitOn ".")[0]! - 1
    let mut endRow := row
    while row > 0 && trim lines[row-1]! != "" do row := row-1
    while endRow+1 < lines.size && trim lines[endRow+1]! != "" do endRow := endRow+1
    first := s!"{row+1}.0"; last := s!"{endRow+1}.end"
  let value ← textCall id #["get",first,last]
  let replacement := if action == "shift_indent" then indentText value (arg.toInt?.getD 4)
    else if action == "change_case" then if truth arg then value.toLower else value.toUpper
    else fillText value
  textCmd id #["edit","separator"]; textCmd id #["replace",first,last,replacement]; textCmd id #["edit","separator"]

def matchBracket (id : String) (extend : Bool) : IO Unit := do
  let text ← contents id
  let offset := (← textCall id #["get","1.0","insert"]).length
  let found := (delimiter text offset).orElse (fun _ => if offset > 0 then delimiter text (offset-1) else none)
  if let some index := found then
    let target ← textCall id #["index",s!"1.0+{index}c"]
    if extend then selectTo id target else deselect id; textCmd id #["mark","set","insert",target]
    textCmd id #["see",target]
  else cmd #["bell"]

def bookmark (id : String) (go extend : Bool) : IO Unit := do
  let some value ← ask id (if go then "Go to Mark" else "Set Mark") "Mark name (a–z)" "a" | return
  let name := trim value |>.toLower
  if name.length != 1 || !(name.toList.all fun c => c >= 'a' && c <= 'z') then return
  let mark := "bookmark_"++name
  if go then
    if !(← words (← textCall id #["mark","names"])).contains mark then alert id "Mark" "That mark is not set."; return
    let target ← textCall id #["index",mark]
    if extend then selectTo id target else deselect id; textCmd id #["mark","set","insert",target]
    textCmd id #["see",target]
  else textCmd id #["mark","set",mark,"insert"]

def cancelOperation (id : String) : IO Unit := do
  let w ← getWindow id
  if let some job := w.job then try job.child.kill catch _ => pure ()
  change id fun c => {c with recording:=false,replaying:=false,repeatLeft:=0,job:=none}
  deselect id

def launchShell (command input : String) (cwd : Option System.FilePath := none) : IO (RunningChild × Task (Except IO.Error IO.Process.Output)) := do
  let spawnArgs : IO.Process.SpawnArgs := {
    cmd:="/bin/sh",args:=#["-c",command],
    cwd:=cwd,
    stdin:=.piped,stdout:=.piped,stderr:=.piped,setsid:=true}
  let (stdin,child) ← (← IO.Process.spawn spawnArgs).takeStdin
  let writer ← IO.asTask (stdin.putStr input *> stdin.flush) .dedicated
  let task ← IO.asTask (do
    let output ← IO.asTask child.stdout.readToEnd .dedicated
    let stderr ← child.stderr.readToEnd
    let exitCode ← child.wait
    let stdout ← IO.ofExcept output.get
    -- A command may legitimately exit without consuming all of its input.
    try IO.ofExcept writer.get catch _ => pure ()
    return {exitCode,stdout,stderr} : IO IO.Process.Output) .dedicated
  return (child,task)

def startShell (id command : String) (filter inline : Bool) : IO Unit := do
  let w ← getWindow id
  if w.job.isSome then alert id "Shell" "A command is already running. Cancel it first."; return
  let rs ← ranges id
  if filter && rs.size != 1 then alert id "Filter Selection" "Select one continuous range first."; return
  let input ← if filter then selected id else pure ""
  let (child,task) ← launchShell command input (if w.doc.path == "" then none else (System.FilePath.mk w.doc.path).parent)
  let before ← contents id
  let rs ← if inline then pure #[(← textCall id #["index","insert lineend"],← textCall id #["index","insert lineend"])] else pure rs
  change id fun c => {c with job:=some {child,task,before,ranges:=rs,filter,inline}}
  feedback id "Shell command running…"
  cmd #["after","100",← actionScript id #["pollshell"]]

def checkExternal (id : String) : IO Unit := do
  let w ← getWindow id
  if w.doc.path == "" || w.busy || (← tk #["grab","current",id]) != "" then return
  change id fun c => {c with busy:=true}
  try
    let current ← readOptional w.doc.path
    if current.isNone then
      if w.doc.original.isSome && !w.unavailable then
        change id fun c => {c with unavailable:=true}
        alert id "File unavailable" "The file is no longer available. Your open text has been kept."
      return
    change id fun c => {c with unavailable:=false}
    if current == w.seen then return
    change id fun c => {c with seen:=current}
    if current == w.doc.original then return
    let warning := if ← dirty id then " Reloading will discard your unsaved changes." else ""
    if (← message id "File changed" ("This file changed outside the editor. Reload from file?"++warning) "yesno") == "yes" then reload id false
  catch e =>
    if !w.unavailable then
      change id fun c => {c with unavailable:=true}
      alert id "File unavailable" (toString e++"\nYour open text has been kept.")
  finally change id fun c => {c with busy:=false}

-- Classic bindings retained from the original editor.
def shortcuts : Array (String × Array String) := #[
  ("Control-n", #["new"]),
  ("Control-Shift-N", #["new"]),
  ("Control-o", #["open"]),
  ("Control-y", #["open_selected"]),
  ("Control-w", #["close"]),
  ("Control-s", #["save"]),
  ("Control-Shift-S", #["save","1"]),
  ("Control-Shift-E", #["revert"]),
  ("Alt-i", #["include_file"]),
  ("Control-p", #["print_text"]),
  ("Control-q", #["quit_all"]),
  ("Control-z", #["undo","0"]),
  ("Control-Shift-Z", #["undo","1"]),
  ("Control-x", #["clipboard","cut"]),
  ("Control-c", #["clipboard","copy"]),
  ("Control-v", #["clipboard","paste"]),
  ("Control-Shift-V", #["paste_column"]),
  ("Control-a", #["select_all"]),
  ("Control-9", #["shift_indent","-4"]),
  ("Control-0", #["shift_indent","4"]),
  ("Control-Shift-parenleft", #["shift_indent","-1"]),
  ("Control-Shift-parenright", #["shift_indent","1"]),
  ("Control-6", #["change_case","0"]),
  ("Control-Shift-asciicircum", #["change_case","1"]),
  ("Control-j", #["fill_paragraph"]),
  ("Control-Alt-l", #["insert_text","\u000c"]),
  ("Control-Alt-i", #["insert_control"]),
  ("Control-f", #["find_dialog","0"]),
  ("Control-Shift-F", #["find_dialog","1"]),
  ("Control-g", #["find_next","0"]),
  ("Control-Shift-G", #["find_next","1"]),
  ("Control-h", #["find_selection","0"]),
  ("Control-Shift-H", #["find_selection","1"]),
  ("Control-i", #["incremental_search","0"]),
  ("Control-Shift-I", #["incremental_search","1"]),
  ("Control-r", #["find_dialog","0","1"]),
  ("Control-Shift-R", #["find_dialog","1","1"]),
  ("Control-t", #["replace_again","0","1"]),
  ("Control-Shift-T", #["replace_again","1","1"]),
  ("Alt-t", #["replace_again","0","0"]),
  ("Alt-Shift-T", #["replace_again","1","0"]),
  ("Control-l", #["go_to_line"]),
  ("Control-e", #["go_to_selected"]),
  ("Alt-m", #["mark_dialog","0","0"]),
  ("Alt-g", #["mark_dialog","1","0"]),
  ("Alt-Shift-G", #["mark_dialog","1","1"]),
  ("Control-m", #["match_bracket","0"]),
  ("Control-Shift-M", #["match_bracket","1"]),
  ("Control-d", #["find_definition","0"]),
  ("Control-apostrophe", #["find_definition","1"]),
  ("Alt-a", #["toggle_status"]),
  ("Insert", #["toggle_overtype"]),
  ("Alt-r", #["shell_command","1"]),
  ("Alt-x", #["shell_command","0"]),
  ("Control-KP_Enter", #["shell_line"]),
  ("Control-period", #["cancel_operation"]),
  ("Alt-k", #["toggle_record"]),
  ("Control-k", #["replay"]),
  ("Control-comma", #["repeat_action"]),
  ("Control-2", #["split_pane"]),
  ("Control-1", #["close_pane"]),
  ("Control-plus", #["change_font_size","1"]),
  ("Control-equal", #["change_font_size","1"]),
  ("Control-minus", #["change_font_size","-1"]),
  ("Control-KP_Add", #["change_font_size","1"]),
  ("Control-KP_Subtract", #["change_font_size","-1"]),
  ("Control-Prior", #["switch_document","-1"]),
  ("Control-Next", #["switch_document","1"]),
  ("Alt-Home", #["switch_document","0"]),
  ("Control-slash", #["select_all"]),
  ("Control-backslash", #["deselect"]),
  ("Control-u", #["delete_span","start"]),
  ("Control-BackSpace", #["delete_span","word"]),
  ("Control-Delete", #["delete_span","end"]),
  ("Control-Insert", #["clipboard","copy"]),
  ("Shift-Insert", #["clipboard","paste"]),
  ("Shift-Delete", #["clipboard","cut"]),
  ("Control-Shift-Insert", #["primary_to_cursor","0","0"]),
  ("Control-Shift-Delete", #["primary_to_cursor","1","0"]),
  ("Control-Alt-Shift-Insert", #["primary_to_cursor","0","1"]),
  ("Control-Alt-Shift-Delete", #["primary_to_cursor","1","1"]),
  ("Control-Return", #["newline","1"]),
  ("Shift-Return", #["newline","0"]),
  ("Control-Tab", #["insert_text","\t"]),
  ("Escape", #["cancel_operation"]),
  ("F10", #["activate_menu"]),
  ("F1", #["shortcut_help"]),
  ("Undo", #["undo","0"]),
  ("Redo", #["undo","1"]),
  ("Copy", #["clipboard","copy"]),
  ("Cut", #["clipboard","cut"]),
  ("Paste", #["clipboard","paste"]),
  ("Cancel", #["cancel_operation"]),
  ("Left", #["move_key","Left","0","0","0"]),
  ("Shift-Left", #["move_key","Left","0","1","0"]),
  ("Alt-Shift-Left", #["move_key","Left","0","1","1"]),
  ("Control-Left", #["move_key","Left","1","0","0"]),
  ("Control-Shift-Left", #["move_key","Left","1","1","0"]),
  ("Control-Alt-Shift-Left", #["move_key","Left","1","1","1"]),
  ("Right", #["move_key","Right","0","0","0"]),
  ("Shift-Right", #["move_key","Right","0","1","0"]),
  ("Alt-Shift-Right", #["move_key","Right","0","1","1"]),
  ("Control-Right", #["move_key","Right","1","0","0"]),
  ("Control-Shift-Right", #["move_key","Right","1","1","0"]),
  ("Control-Alt-Shift-Right", #["move_key","Right","1","1","1"]),
  ("Up", #["move_key","Up","0","0","0"]),
  ("Shift-Up", #["move_key","Up","0","1","0"]),
  ("Alt-Shift-Up", #["move_key","Up","0","1","1"]),
  ("Control-Up", #["move_key","Up","1","0","0"]),
  ("Control-Shift-Up", #["move_key","Up","1","1","0"]),
  ("Control-Alt-Shift-Up", #["move_key","Up","1","1","1"]),
  ("Down", #["move_key","Down","0","0","0"]),
  ("Shift-Down", #["move_key","Down","0","1","0"]),
  ("Alt-Shift-Down", #["move_key","Down","0","1","1"]),
  ("Control-Down", #["move_key","Down","1","0","0"]),
  ("Control-Shift-Down", #["move_key","Down","1","1","0"]),
  ("Control-Alt-Shift-Down", #["move_key","Down","1","1","1"]),
  ("Home", #["move_key","Home","0","0","0"]),
  ("Shift-Home", #["move_key","Home","0","1","0"]),
  ("Alt-Shift-Home", #["move_key","Home","0","1","1"]),
  ("Control-Home", #["move_key","Home","1","0","0"]),
  ("Control-Shift-Home", #["move_key","Home","1","1","0"]),
  ("Control-Alt-Shift-Home", #["move_key","Home","1","1","1"]),
  ("End", #["move_key","End","0","0","0"]),
  ("Shift-End", #["move_key","End","0","1","0"]),
  ("Alt-Shift-End", #["move_key","End","0","1","1"]),
  ("Control-End", #["move_key","End","1","0","0"]),
  ("Control-Shift-End", #["move_key","End","1","1","0"]),
  ("Control-Alt-Shift-End", #["move_key","End","1","1","1"]),
  ("Prior", #["move_key","Prior","0","0","0"]),
  ("Shift-Prior", #["move_key","Prior","0","1","0"]),
  ("Alt-Shift-Prior", #["move_key","Prior","0","1","1"]),
  ("Control-Shift-Prior", #["move_key","Prior","1","1","0"]),
  ("Control-Alt-Shift-Prior", #["move_key","Prior","1","1","1"]),
  ("Next", #["move_key","Next","0","0","0"]),
  ("Shift-Next", #["move_key","Next","0","1","0"]),
  ("Alt-Shift-Next", #["move_key","Next","0","1","1"]),
  ("Control-Shift-Next", #["move_key","Next","1","1","0"]),
  ("Control-Alt-Shift-Next", #["move_key","Next","1","1","1"]),
  ("BackSpace", #["delete_span","back"]),
  ("Delete", #["delete_span","forward"]),
  ("Return", #["newline","0"]),
  ("KP_Enter", #["newline","0"]),
  ("Tab", #["insert_text","\t"]),
  ("Control-space", #["set_anchor"]),
  ("Shift-Select", #["extend_anchor","0"]),
  ("Control-Shift-space", #["extend_anchor","0"]),
  ("Control-Alt-Shift-space", #["extend_anchor","1"]),
  ("Control-Alt-a", #["insert_text","\u0001"]),
  ("Control-Alt-b", #["insert_text","\u0002"]),
  ("Control-Alt-c", #["insert_text","\u0003"]),
  ("Control-Alt-d", #["insert_text","\u0004"]),
  ("Control-Alt-e", #["insert_text","\u0005"]),
  ("Control-Alt-f", #["insert_text","\u0006"]),
  ("Control-Alt-g", #["insert_text","\u0007"]),
  ("Control-Alt-h", #["insert_text","\u0008"]),
  ("Control-Alt-j", #["insert_text","\n"]),
  ("Control-Alt-k", #["insert_text","\u000b"]),
  ("Control-Alt-m", #["insert_text","\r"]),
  ("Control-Alt-n", #["insert_text","\u000e"]),
  ("Control-Alt-o", #["insert_text","\u000f"]),
  ("Control-Alt-p", #["insert_text","\u0010"]),
  ("Control-Alt-q", #["insert_text","\u0011"]),
  ("Control-Alt-r", #["insert_text","\u0012"]),
  ("Control-Alt-s", #["insert_text","\u0013"]),
  ("Control-Alt-t", #["insert_text","\u0014"]),
  ("Control-Alt-u", #["insert_text","\u0015"]),
  ("Control-Alt-v", #["insert_text","\u0016"]),
  ("Control-Alt-w", #["insert_text","\u0017"]),
  ("Control-Alt-x", #["insert_text","\u0018"]),
  ("Control-Alt-y", #["insert_text","\u0019"]),
  ("Control-Alt-z", #["insert_text","\u001a"]),
  ("Control-Alt-at", #["insert_text","\u0000"]),
  ("Control-Alt-bracketleft", #["insert_text","\u001b"]),
  ("Control-Alt-backslash", #["insert_text","\u001c"]),
  ("Control-Alt-bracketright", #["insert_text","\u001d"]),
  ("Control-Alt-asciicircum", #["insert_text","\u001e"]),
  ("Control-Alt-underscore", #["insert_text","\u001f"])
]

-- Tk's %A substitution quotes a command argument, not an expression operand.
-- Receive it in a procedure first so expr sees a variable instead of raw text.
def keyHandlerScript : String :=
  "proc ::editorKey {id character state} {\n" ++
  "  if {$character ne {} && ($state & 12) == 0} {\n" ++
  "    editor $id insert_text $character\n" ++
  "    return -code break\n" ++
  "  }\n" ++
  "}"

def installBindings (id pane : String) : IO Unit := do
  script keyHandlerScript
  let tag := "EditorKeys"++pane
  cmd #["bindtags",pane,← tk #["list",tag,pane,"Text",id,"all"]]
  for (key,args) in shortcuts do
    let pattern := if ["Copy","Cut","Paste"].contains key then "<<"++key++">>" else "<"++key++">"
    bindAction tag pattern id args
    if onMac && (key.splitOn "Control-").length > 1 then
      bindAction tag ("<"++key.replace "Control-" "Command-"++">") id args
  cmd #["bind",pane,"<FocusIn>",← actionScript id #["focus",pane]]
  cmd #["bind",tag,"<KeyPress>","::editorKey "++id++" %A %s"]
  cmd #["bind",tag,"<Button-1>",s!"editor {id} mouse {pane} %x %y; break"]
  for pattern in ["<Double-Button-1>","<Triple-Button-1>","<Shift-Button-1>","<Double-Shift-Button-1>","<Triple-Shift-Button-1>","<Control-Button-1>"] do
    bindAction tag pattern id #["focus",pane] false
  bindAction pane "<KeyRelease>" id #["status"] false
  bindAction pane "<ButtonRelease-1>" id #["status"] false
  bindAction pane "<<Modified>>" id #["modified"] false
  cmd #[pane,"tag","configure","rectsel","-background","#9ac7ef","-foreground","#171717"]

def menuItems : List (String × List (String × Array String × String)) := [
  ("File",[("New",#["new"],"Cmd+N"),("Open…",#["open"],"Cmd+O"),("Open Selected",#["open_selected"],"Cmd+Y"),
    ("Include File…",#["include_file"],""),("Save",#["save"],"Cmd+S"),("Save As…",#["save","1"],"Shift+Cmd+S"),
    ("Revert",#["revert"],""),("Close",#["close"],"Cmd+W"),("Print…",#["print_text"],"Cmd+P"),("Quit",#["quit_all"],"Cmd+Q")]),
  ("Edit",[("Undo",#["undo","0"],"Cmd+Z"),("Redo",#["undo","1"],"Shift+Cmd+Z"),
    ("Cut",#["clipboard","cut"],"Cmd+X"),("Copy",#["clipboard","copy"],"Cmd+C"),("Paste",#["clipboard","paste"],"Cmd+V"),
    ("Paste Column",#["paste_column"],""),("Select All",#["select_all"],"Cmd+A"),("Shift Left",#["shift_indent","-4"],""),
    ("Shift Right",#["shift_indent","4"],""),("Uppercase",#["change_case","0"],""),("Lowercase",#["change_case","1"],""),
    ("Fill Paragraph",#["fill_paragraph"],"Cmd+J")]),
  ("Search",[("Find / Replace…",#["find_dialog"],"Cmd+F"),("Find Next",#["find_next","0"],"Cmd+G"),
    ("Find Previous",#["find_next","1"],"Shift+Cmd+G"),("Find Selection",#["find_selection"],"Cmd+H"),
    ("Incremental Search",#["incremental_search"],"Cmd+I"),("Go to Line…",#["go_to_line"],"Cmd+L"),
    ("Set Mark…",#["mark_dialog","0"],""),("Go to Mark…",#["mark_dialog","1"],""),
    ("Find Matching",#["match_bracket"],"Cmd+M"),("Find Definition",#["find_definition"],"Cmd+D"),
    ("Call Tip",#["find_definition","1"],"Cmd+'")]),
  ("Preferences",[("Wrap Lines",#["wrap"],""),("Show / Hide Status",#["toggle_status"],""),
    ("Increase Font Size",#["change_font_size","1"],"Cmd++"),("Decrease Font Size",#["change_font_size","-1"],"Cmd+-")]),
  ("Shell",[("Execute Command…",#["shell_command","0"],""),("Filter Selection…",#["shell_command","1"],""),
    ("Execute Current Line",#["shell_line"],""),("Cancel",#["cancel_operation"],"Cmd+.")]),
  ("Macro",[("Learn / Finish",#["toggle_record"],""),("Replay",#["replay"],"Cmd+K"),("Repeat…",#["repeat_action"],"")]),
  ("Windows",[("Split Pane",#["split_pane"],"Cmd+2"),("Close Pane",#["close_pane"],"Cmd+1"),
    ("Next Document",#["switch_document","1"],""),("Previous Document",#["switch_document","-1"],"")]),
  ("Help",[("Keyboard Shortcuts",#["shortcut_help"],"F1"),("About EditorLean",#["about"],"")])]

def newWindow (doc : Document := {}) : IO String := do
  serial.modify (·+1)
  let id := s!".e{← serial.get}"
  let pane := id++".frame.t0"
  cmd #["toplevel",id]; cmd #["wm","geometry",id,"950x700"]; cmd #["wm","minsize",id,"500","300"]
  cmd #["wm","protocol",id,"WM_DELETE_WINDOW",← actionScript id #["close"]]
  cmd #["frame",id++".frame"]; cmd #["pack",id++".frame","-fill","both","-expand","1"]
  cmd #["grid","rowconfigure",id++".frame","0","-weight","1"]
  cmd #["grid","columnconfigure",id++".frame","0","-weight","1"]
  cmd #["text",pane,"-undo","1","-maxundo","-1","-wrap","none","-font",← monoFont 13,"-background","#fffff4",
    "-foreground","#171717","-insertbackground","#171717","-exportselection","0","-selectbackground","#9ac7ef",
    "-selectforeground","#171717","-inactiveselectbackground","#9ac7ef","-padx","8","-pady","6"]
  cmd #["grid",pane,"-row","0","-column","0","-sticky","nsew"]
  cmd #["scrollbar",id++".frame.v"]; cmd #["scrollbar",id++".frame.h","-orient","horizontal"]
  cmd #["grid",id++".frame.v","-row","0","-column","1","-sticky","ns"]
  cmd #["grid",id++".frame.h","-row","1","-column","0","-sticky","ew"]
  cmd #["label",id++".status","-anchor","w","-relief","sunken","-padx","6"]
  cmd #["pack",id++".status","-fill","x"]
  cmd #["menu",id++".menu","-tearoff","0"]; cmd #[id,"configure","-menu",id++".menu"]
  for (caption,items) in menuItems do
    let m := id++".menu."++caption.toLower
    cmd #["menu",m,"-tearoff","0"]; cmd #[id++".menu","add","cascade","-label",caption,"-menu",m]
    for (label,args,accelerator) in items do
      cmd #[m,"add","command","-label",label,"-accelerator",accelLabel accelerator,"-command",← actionScript id args]
  windows.modify (·.push {id,pane,panes:=#[pane]})
  installBindings id pane
  focusPane id pane
  install id doc
  cmd #["after","1500",← actionScript id #["watch"]]
  return id

def openFile (id path : String) : IO String := do
  let doc ← openDocument path
  if let some existing := (← windows.get).find? (·.doc.path == doc.path) then
    cmd #["raise",existing.id]; cmd #["focus",existing.pane]; return existing.id
  let w ← getWindow id
  if w.doc.path != "" || (← dirty id) then return ← newWindow doc
  install id doc
  return id

def layoutPanes (id : String) : IO Unit := do
  let w ← getWindow id
  for (pane,row) in w.panes.toList.zipIdx do
    cmd #["grid",pane,"-row",toString row,"-column","0","-sticky","nsew"]
    cmd #["grid","rowconfigure",id++".frame",toString row,"-weight","1"]
  cmd #["grid",id++".frame.v","-rowspan",toString w.panes.size]
  cmd #["grid",id++".frame.h","-row",toString w.panes.size]
  cmd #["grid","rowconfigure",id++".frame",toString w.panes.size,"-weight","0"]
  focusPane id w.pane

def splitPane (id : String) : IO Unit := do
  let w ← getWindow id
  serial.modify (·+1)
  let pane := id++s!".frame.p{← serial.get}"
  textCmd id #["peer","create",pane,"-font",← monoFont w.font,"-background","#fffff4","-foreground","#171717",
    "-insertbackground","#171717","-selectbackground","#9ac7ef","-selectforeground","#171717",
    "-inactiveselectbackground","#9ac7ef","-exportselection","0","-wrap",← textCall id #["cget","-wrap"],"-padx","8","-pady","6"]
  change id fun c => {c with pane,panes:=c.panes.push pane}
  installBindings id pane; layoutPanes id; cmd #["focus",pane]

def closePane (id : String) : IO Unit := do
  let w ← getWindow id
  if w.panes.size <= 1 then return
  let panes := w.panes.filter (· != w.pane)
  change id fun c => {c with panes,pane:=panes[0]!}
  cmd #["destroy",w.pane]; layoutPanes id; cmd #["focus",panes[0]!]

def closeWindow (id : String) : IO Unit := do
  cancelOperation id
  windows.modify (·.filter (·.id != id))
  cmd #["destroy",id]
  if (← windows.get).isEmpty then cmd #["destroy","."]

def pollShell (id : String) : IO Unit := do
  let some job := (← getWindow id).job | return
  if !(← IO.hasFinished job.task) then
    cmd #["after","100",← actionScript id #["pollshell"]]; return
  change id fun c => {c with job:=none}
  let out ← IO.ofExcept job.task.get
  if out.exitCode != 0 then alert id "Shell command failed" s!"Exit status {out.exitCode}\n{out.stderr}"; return
  if (job.filter || job.inline) && (← contents id) == job.before then
    textCmd id #["edit","separator"]
    textCmd id #["replace",job.ranges[0]!.1,job.ranges[0]!.2,(if job.inline then "\n" else "")++out.stdout]
    textCmd id #["edit","separator"]
  else if out.stdout != "" then
    let result ← newWindow
    insertText result out.stdout
  if out.stderr != "" then alert id "Shell output (stderr)" out.stderr
  feedback id "Shell command finished."

def definition (id : String) (tip : Bool) : IO Unit := do
  let mut name ← selected id
  if name == "" then name ← textCall id #["get","insert wordstart","insert wordend"]
  name := trim name
  if name == "" then return
  let w ← getWindow id
  let mut folder ← if w.doc.path == "" then IO.currentDir else pure ((System.FilePath.mk w.doc.path).parent.getD ".")
  let mut tags := ""
  repeat
    if ← (folder / "tags").pathExists then tags := (folder / "tags").toString; break
    let parent := folder.parent.getD folder
    if parent == folder then break
    folder := parent
  if tags == "" then tags ← tk #["tk_getOpenFile","-parent",id,"-title","Choose a ctags file"]
  if tags == "" then return
  let data ← IO.FS.readFile tags
  for line in data.splitOn "\n" do
    let parts := line.splitOn "\t" |>.toArray
    if parts.size < 3 || parts[0]! != name then continue
    let path := ((System.FilePath.mk tags).parent.getD "." / parts[1]!).toString
    let address := (parts[2]!.splitOn ";\"")[0]!
    let doc ← openDocument path
    let lines := doc.text.splitOn "\n" |>.toArray
    let mut row := address.toNat?.getD 0
    if row == 0 then
      if !(address.startsWith "/^" && address.endsWith "$/") then
        alert id "Definition" "This tags entry needs a numeric line or a /^literal line$/ address."; return
      let literal := charSlice address 2 (address.length-2) |>.replace "\\/" "/" |>.replace "\\\\" "\\"
      for i in [0:lines.size] do
        if lines[i]! == literal then row := i+1; break
    if row == 0 then alert id "Definition" "The definition was not found in the source file."; return
    if tip then alert id ("Call Tip — "++name) (join ((lines.toList.drop (row-1)).take 5))
    else
      let target ← openFile id path
      textCmd target #["mark","set","insert",s!"{row}.0"]; textCmd target #["see","insert"]
    return
  alert id "Definition" ("No tags entry for "++name)

def printText (id : String) : IO Unit := do
  let value ← selected id
  let value ← if value == "" then contents id else pure value
  let escape := fun s : String => s.replace "&" "&amp;" |>.replace "<" "&lt;" |>.replace ">" "&gt;" |>.replace "\"" "&quot;"
  let (handle,path) ← IO.FS.createTempFile
  handle.putStr ("<!doctype html><meta charset='utf-8'><title>Print — EditorLean</title><style>pre{white-space:pre-wrap;font:12px monospace}</style><pre>"++escape value++"</pre>")
  handle.flush
  let html := path.toString++".html"
  IO.FS.rename path html
  if onMac then discard <| IO.Process.output {cmd:="/usr/bin/open",args:=#[html]}
  else
    -- xdg-open may hand the file to a browser that inherits its pipes, so
    -- detach completely instead of collecting output; reap it in the background.
    let child ← IO.Process.spawn {cmd:="xdg-open",args:=#[html],stdin:=.null,stdout:=.null,stderr:=.null}
    discard <| IO.asTask child.wait .dedicated
  alert id "Print" s!"The print preview opened in your browser. Use {if onMac then "Command-P" else "Ctrl+P"} there to print."

def dispatch (id action : String) (args : Array String) : IO Unit := do
  let a := args[0]?.getD ""
  let b := args[1]?.getD ""
  let w ← getWindow id
  match action with
  | "status" => pure ()
  | "focus" => focusPane id a
  | "modified" => if truth (← textCall id #["edit","modified"]) then textCmd id #["edit","modified","0"]
  | "mouse" =>
    focusPane id a; deselect id
    let position ← textCall id #["index","@0,"++args[2]!]
    let box ← words (← textCall id #["bbox",position++" lineend"])
    let x := if box.size >= 4 && b.toInt?.getD 0 > box[0]!.toInt?.getD 0 &&
      args[2]!.toInt?.getD 0 >= box[1]!.toInt?.getD 0 && args[2]!.toInt?.getD 0 < box[1]!.toInt?.getD 0 + box[3]!.toInt?.getD 0
      then box[0]! else b
    cmd #["tk::TextButton1",a,x,args[2]!]
    cmd #["focus",a]
  | "insert_text" => insertText id a
  | "newline" =>
    let indentation ← if truth a then pure (leading (← textCall id #["get","insert linestart","insert"])) else pure ""
    insertText id ("\n"++indentation)
  | "insert_control" =>
    if let some value ← ask id "Insert Control Character" "ASCII control code (0–31 or 127)" "0" then
      if let some n := value.toNat? then
        if n <= 31 || n == 127 then insertText id (String.singleton (Char.ofNat n))
  | "delete_span" => deleteSpan id a
  | "move_key" => moveCursor id a (truth b) (truth (args[2]?.getD "")) (truth (args[3]?.getD ""))
  | "clipboard" => clipboard id a
  | "paste_column" => pasteColumn id (← selectionGet #["clipboard","get"])
  | "primary_to_cursor" =>
    let mut value ← selected id
    if value == "" then value ← selectionGet #["selection","get","-selection","PRIMARY"]
    if truth a then
      for (first,last) in (← ranges id).reverse do textCmd id #["delete",first,last]
    deselect id
    if truth b then pasteColumn id value else insertText id value
  | "select_all" => deselect id; textCmd id #["tag","add","sel","1.0","end-1c"]
  | "deselect" => deselect id
  | "set_anchor" =>
    let cursor ← textCall id #["index","insert"]
    change id fun c => {c with anchor:=cursor}
  | "extend_anchor" => selectTo id (← textCall id #["index","insert"]) (truth a)
  | "shift_indent" | "change_case" | "fill_paragraph" => transform id action a
  | "undo" => try textCmd id #["edit",if truth a then "redo" else "undo"] catch _ => cmd #["bell"]
  | "new" => discard <| newWindow
  | "open" =>
    let path ← if a == "" then tk #["tk_getOpenFile","-parent",id] else pure a
    if path != "" then discard <| openFile id path
  | "open_selected" =>
    let mut path ← selected id
    if path == "" then path ← textCall id #["get","insert wordstart","insert wordend"]
    path := trim path
    if (path.startsWith "\"" && path.endsWith "\"") || (path.startsWith "'" && path.endsWith "'") then path := charSlice path 1 (path.length-1)
    if path != "" then
      if !(System.FilePath.mk path).isAbsolute && !(path.startsWith "~") && w.doc.path != "" then
        path := ((System.FilePath.mk w.doc.path).parent.getD "." / path).toString
      discard <| openFile id path
  | "include_file" =>
    let path ← tk #["tk_getOpenFile","-parent",id]
    if path != "" then insertText id (← openDocument path).text
  | "save" => discard <| save id (truth a)
  | "revert" => reload id
  | "close" => if ← confirmDiscard id then closeWindow id
  | "quit_all" =>
    let all ← windows.get
    for window in all do if !(← confirmDiscard window.id) then return
    for window in all do closeWindow window.id
  | "print_text" => printText id
  | "find_dialog" => findDialog id (truth a) (truth b)
  | "find" | "find_next" =>
    if w.query == "" && !(← widgetExists (id++".find")) then findDialog id (truth a) else search id (truth a)
  | "find_selection" =>
    let value ← selected id
    if value != "" then
      change id fun c => {c with query:=value}
      if ← widgetExists (id++".find") then cmd #["set",id++"_query",value]
      search id (truth a)
  | "incremental_search" =>
    let origin ← textCall id #["index","insert"]
    change id fun c => {c with incrementalOrigin:=origin}
    findDialog id (truth a)
    cmd #["bind",id++".find.query","<KeyRelease>",← actionScript id #["increment",a]]
  | "increment" =>
    deselect id
    textCmd id #["mark","set","insert",w.incrementalOrigin]
    search id (truth a)
  | "replace" => replaceMatches id false (truth a)
  | "replaceall" => replaceMatches id true
  | "replace_again" =>
    if w.query == "" then findDialog id (truth a) true else
      if (← selected id) != w.query then search id (truth a)
      if (← selected id) != w.query then return
      let rs ← ranges id
      let first := rs[0]!.1
      textCmd id #["edit","separator"]
      textCmd id #["replace",first,rs[0]!.2,w.replacement]
      textCmd id #["mark","set","insert",if truth a then first else first++s!"+{w.replacement.length}c"]
      deselect id
      textCmd id #["edit","separator"]
      if truth b then search id (truth a)
  | "closefind" =>
    if ← widgetExists (id++".find") then
      let q ← tk #["set",id++"_query"]; let r ← tk #["set",id++"_replacement"]
      change id fun c => {c with query:=q,replacement:=r}
      cmd #["destroy",id++".find"]
      cmd #["focus",w.pane]
  | "go_to_line" | "go_to_selected" =>
    let value ← if action == "go_to_line" then ask id "Go to Line" "Line number" "1" else pure (some (trim (← selected id)))
    if let some value := value then
      let parts := value.splitOn ":" |>.toArray
      if let some row := parts[0]!.toNat? then
        let col := (parts[1]?.getD "1").toNat?.getD 1 - 1
        deselect id
        textCmd id #["mark","set","insert",s!"{max 1 row}.{col}"]; textCmd id #["see","insert"]; cmd #["focus",w.pane]
  | "mark_dialog" => bookmark id (truth a) (truth b)
  | "match_bracket" => matchBracket id (truth a)
  | "find_definition" => definition id (truth a)
  | "wrap" =>
    let wrap := if (← textCall id #["cget","-wrap"]) == "none" then "word" else "none"
    for pane in w.panes do cmd #[pane,"configure","-wrap",wrap]
  | "toggle_status" =>
    if truth (← tk #["winfo","ismapped",id++".status"]) then cmd #["pack","forget",id++".status"]
    else cmd #["pack",id++".status","-fill","x"]
  | "toggle_overtype" =>
    change id fun c => {c with overtype:=!c.overtype}
    textCmd id #["configure","-insertwidth",if w.overtype then "2" else "8"]
  | "change_font_size" =>
    let size := max 6 (min 48 (Int.ofNat w.font + a.toInt?.getD 1)).toNat
    change id fun c => {c with font:=size}
    for pane in w.panes do cmd #[pane,"configure","-font",← monoFont size]
  | "split_pane" => splitPane id
  | "close_pane" => closePane id
  | "switch_document" =>
    let all ← windows.get
    let offset := a.toInt?.getD 1
    let index := all.toList.findIdx (·.id == id)
    let next := all[((Int.ofNat index + offset + Int.ofNat all.size) % Int.ofNat all.size).toNat]!
    let target ← if offset == 0 then
      let prior ← previous.get
      pure ((all.find? (·.id == prior)).getD next)
      else pure next
    cmd #["raise",target.id]; cmd #["focus",target.pane]
  | "shell_command" =>
    if let some value ← ask id (if truth a then "Filter Selection" else "Execute Command") "Shell command" "" then
      if trim value != "" then startShell id value (truth a) false
  | "shell_line" => startShell id (← textCall id #["get","insert linestart","insert lineend"]) false true
  | "pollshell" => pollShell id
  | "cancel_operation" => cancelOperation id
  | "toggle_record" =>
    change id fun c => {c with recording:=!c.recording,recorded:=if c.recording then c.recorded else #[]}
  | "replay" =>
    if !w.recorded.isEmpty && !w.replaying then
      change id fun c => {c with recording:=false,replaying:=true,repeatLeft:=c.recorded.size}
      cmd #["after","1",← actionScript id #["macrostep","0"]]
  | "macrostep" =>
    if !w.replaying || w.repeatLeft == 0 then return
    let index := number a
    if index < w.recorded.size then cmd (#["editor",id] ++ w.recorded[index]!)
    change id fun c => {c with repeatLeft:=c.repeatLeft-1,replaying:=index+1 < c.recorded.size}
    if index+1 < w.recorded.size then cmd #["after","1",← actionScript id #["macrostep",toString (index+1)]]
  | "repeat_action" =>
    if w.lastAction.isEmpty then return
    if let some value ← ask id "Repeat Last Action" "Number of repetitions" "10" then
      let n := min 100000 (number value)
      change id fun c => {c with repeatLeft:=n,replaying:=n > 0}
      cmd #["after","1",← actionScript id #["repeatstep"]]
  | "repeatstep" =>
    if !w.replaying || w.repeatLeft == 0 then return
    cmd (#["editor",id] ++ w.lastAction)
    change id fun c => {c with repeatLeft:=c.repeatLeft-1,replaying:=c.repeatLeft > 1}
    if w.repeatLeft > 1 then cmd #["after","1",← actionScript id #["repeatstep"]]
  | "watch" =>
    try checkExternal id finally
      if ← widgetExists id then cmd #["after","1500",← actionScript id #["watch"]]
  | "activate_menu" => cmd #["tk_popup",id++".menu.file",← tk #["winfo","rootx",id],← tk #["winfo","rooty",id],"0"]
  | "shortcut_help" =>
    let help := join (shortcuts.toList.map fun (key,values) => key++"    "++values[0]!)
    let target ← newWindow {text:="EditorLean Keyboard Shortcuts\n\n"++(if onMac then "Control shortcuts also have Command aliases on macOS.\n\n" else "")++help}
    cmd #["wm","title",target,"Keyboard Shortcuts — EditorLean"]
  | "about" => alert id "About EditorLean" "EditorLean 1.0.4\nNEdit-style editor written in Lean 4.\nCompiled to C with lean -c, then to native code with leanc.\nTcl/Tk supplies the desktop widgets."
  | _ => throw <| IO.userError ("Unknown editor action: "++action)

initialize callbackTest : IO.Ref (Array String) ← IO.mkRef #[]
@[export editor_event] def onEvent (args : Array String) : IO Unit := do
  if args[0]?.getD "" == "__test" then callbackTest.set (args.extract 1 args.size); return
  if args.size < 2 then return
  let id ← if args[0]! == "__app" then
    let all ← windows.get
    let current ← active.get
    pure ((all.find? (·.id == current)).getD (all[0]?.getD default)).id
    else pure args[0]!
  let action := args[1]!
  if !(← windows.get).any (·.id == id) then return
  try
    let w ← getWindow id
    let internal := ["focus","status","modified","mouse","watch","pollshell","macrostep","repeatstep","toggle_record","replay","repeat_action","cancel_operation"]
    if !internal.contains action && !w.replaying then
      let event := args.extract 1 args.size
      change id fun c => {c with lastAction:=event,recorded:=if c.recording then c.recorded.push event else c.recorded}
    dispatch id action (args.extract 2 args.size)
    if (← windows.get).any (·.id == id) then updateStatus id
  catch e => alert id "EditorLean" (toString e)

initialize testsPassed : IO.Ref Nat ← IO.mkRef 0
def check (name : String) (condition : Bool) : IO Unit := do
  if !condition then throw <| IO.userError ("FAIL: "++name)
  testsPassed.modify (·+1)
  IO.println ("PASS: "++name)
def expectFailure (name : String) (action : IO Unit) : IO Unit := do
  let failed ← try action; pure false catch _ => pure true
  check name failed

def selfTests : IO Unit := do
  check "native entry point stays on the OS main thread" (← isMainThread)
  let worker ← IO.asTask (tkInit true) .dedicated
  let rejected := match worker.get with
    | .error e => (toString e).startsWith "EditorLean must initialize"
    | .ok _ => false
  check "GUI initialization rejects worker threads before entering the GUI toolkit" rejected
  tkInit false
  check "native startup disables the interactive Wish console path" (← startupConfigured)
  check "native interpreter is noninteractive" ((← tk #["set","tcl_interactive"]) == "0")
  check "native interpreter has no Tcl command-line arguments" ((← tk #["set","argc"]) == "0" && (← tk #["set","argv"]) == "")
  let sample := "α😀漢字\n\"quotes\" {braces} [not a command] $variable ; back\\slash\u0000end"
  check "Tcl string round trip, Unicode and embedded NUL" ((← tk #["set","sample",sample]) == sample)
  let values := #["",sample,"a b","\n"]
  check "Tcl list quoting is lossless" ((← words (← tk (#["list"]++values))) == values)
  cmd (#["editor","__test"]++values)
  check "C callback invokes compiled Lean with exact arguments" ((← callbackTest.get) == values)
  script keyHandlerScript
  for character in ["l", "a", "1", " ", "\"", "'", "{", "}", "[", "]", "$", ";", "\\", "α", "😀", "[set injected 1]"] do
    callbackTest.set #[]
    let binding ← tk #["list","::editorKey","__test",character,"0"]
    let status ← tk #["catch",binding]
    check ("key handler inserts literal " ++ reprStr character)
      (status == "3" && (← callbackTest.get) == #["insert_text",character])
  for (character,state) in [("","0"),("x","4"),("x","8"),("x","12")] do
    callbackTest.set #[]
    let binding ← tk #["list","::editorKey","__test",character,state]
    let status ← tk #["catch",binding]
    check "key handler leaves non-text and shortcut events alone"
      (status == "0" && (← callbackTest.get).isEmpty)
  check "typed text cannot execute Tcl commands" ((← tk #["info","exists","injected"]) == "0")
  expectFailure "Tcl errors cross FFI safely" (cmd #["not_an_editor_command"])
  check "nested delimiter forward" (delimiter "a(b(c)d)e" 1 == some 7)
  check "nested delimiter backward" (delimiter "a(b(c)d)e" 7 == some 1)
  check "unmatched delimiter" (delimiter "(a" 0 == none)
  check "quoted delimiter" (delimiter "\"hello\"" 0 == some 6)
  check "word navigation" (wordBoundary "one two" 7 == 4 && wordBoundary "one two" 0 true == 4)
  check "Unicode word navigation" (wordBoundary "αβ 猫犬" 5 == 3 && wordBoundary "αβ 猫犬" 0 true == 3)
  check "indent multiline" (indentText "a\n b" 2 == "  a\n   b")
  check "unindent spaces and tabs" (indentText "    a\n\tb\n c" (-4) == "a\nb\nc")
  check "fill paragraph" (fillText "  first  second\n  third" == "  first second third")
  for raw in ["plain","line\n","a\r\nb","a\rb","\uFEFFα\r\nβ","a\r\nb\nc\rd",""] do
    let doc ← decodeDocument "" (some raw.toUTF8)
    check "unchanged file keeps its exact bytes" (encodeDocument doc doc.text == raw.toUTF8)
  let bom ← decodeDocument "" (some "\uFEFFa\r\nb".toUTF8)
  check "edited file retains BOM and CRLF" (encodeDocument bom "c\nd" == "\uFEFFc\r\nd".toUTF8)
  expectFailure "invalid UTF-8 rejected" (discard <| decodeDocument "" (some (ByteArray.mk #[255,254])))
  let (handle,temp) ← IO.FS.createTempFile
  handle.flush
  let path := temp.toString
  try
    IO.FS.writeFile path "original\r\n"
    let doc ← openDocument path
    check "open normalizes newlines in memory" (doc.text == "original\n")
    let saved ← saveDocument doc "changed\n" path
    check "atomic save writes preserved newline format" ((← IO.FS.readFile path) == "changed\r\n")
    IO.FS.writeFile path "external edit"
    expectFailure "external change blocks save" (discard <| saveDocument saved "my edit" path)
    check "conflict leaves external bytes untouched" ((← IO.FS.readFile path) == "external edit")
    let saved ← saveDocument saved "forced" path true
    check "explicit overwrite saves" ((← IO.FS.readFile path) == "forced")
    IO.FS.removeFile path
    expectFailure "deleted destination requires confirmation" (discard <| saveDocument saved "again" path)
    let fresh ← openDocument path
    check "new document is empty" (fresh.original.isNone && fresh.text == "")
    discard <| saveDocument fresh "new file" path
    expectFailure "Save As collision blocked" (discard <| saveDocument {} "other" path)
    expectFailure "invalid destination does not damage original" (atomicWrite (path++"/missing") "bad".toUTF8)
    check "failed save preserves bytes" ((← IO.FS.readFile path) == "new file")
    let link := path++"-symlink"
    discard <| IO.Process.output {cmd:="ln",args:=#["-s",path,link]}
    try
      let doc ← openDocument link
      discard <| saveDocument doc "through link" link
      check "symlink save changes target" ((← IO.FS.readFile path) == "through link")
      check "symlink survives save" ((← tk #["file","type",link]) == "link")
    finally IO.FS.removeFile link
    discard <| IO.Process.output {cmd:="chmod",args:=#["640",path]}
    let doc ← openDocument path
    discard <| saveDocument doc "mode kept" path
    check "file permissions survive save" ((← tk #["expr",← tk #["file","attributes",path,"-permissions"]]) == "416")
  finally
    if ← temp.pathExists then IO.FS.removeFile temp
  let large := String.ofList (List.replicate 200000 'x')
  let (_,task) ← launchShell "cat; printf error >&2" large
  let out ← IO.ofExcept task.get
  check "async shell drains large input and both output streams" (out.stdout == large && out.stderr == "error" && out.exitCode == 0)
  let (child,task) ← launchShell "sleep 20" ""
  child.kill
  discard <| IO.ofExcept task.get
  check "shell cancellation reaps process group" (← IO.hasFinished task)
  let (_,task) ← launchShell "printf failure >&2; exit 7" ""
  let out ← IO.ofExcept task.get
  check "shell captures failure status" (out.exitCode == 7 && out.stderr == "failure")
  IO.println s!"{← testsPassed.get} native Lean tests passed."

def guiTests : IO Unit := do
  check "GUI starts on the OS main thread" (← isMainThread)
  tkInit true
  cmd #["wm","withdraw","."]
  let id ← newWindow
  check "GUI editor font uses the chosen monospace family"
    ((← tk #["font","actual",← tk #[(← getWindow id).pane,"cget","-font"],"-family"]) == (← monoFamily))
  -- Modal dialogs become failures in the automated GUI suite.
  script "rename tk_messageBox original_messageBox; proc tk_messageBox {args} {error $args}"
  script "set ::editorTestErrors {}; proc bgerror {message} {lappend ::editorTestErrors $message}"
  cmd #["update"]
  cmd #["focus","-force",(← getWindow id).pane]
  cmd #["update"]
  for key in ["l","space","braceleft"] do
    cmd #["event","generate",(← getWindow id).pane,"<KeyPress>","-keysym",key]
  cmd #["update"]
  check "GUI real key bindings insert letters, spaces and braces once" ((← contents id) == "l {")
  check "GUI typing raises no Tcl background error" ((← tk #["set","::editorTestErrors"]) == "")
  install id {}
  insertText id "α😀 one\nshort\nlast"
  check "GUI Unicode text insertion" ((← contents id) == "α😀 one\nshort\nlast")
  dispatch id "select_all" #[]
  check "GUI selection" ((← selected id) == (← contents id))
  dispatch id "clipboard" #["copy"]
  check "GUI clipboard" ((← tk #["clipboard","get"]) == (← contents id))
  install id {text:="one two one\nshort\nlast"}
  change id fun w => {w with query:="one",replacement:="three"}
  search id
  check "GUI find first" ((← selected id) == "one" && (← textCall id #["index","sel.first"]) == "1.0")
  search id
  check "GUI find next" ((← textCall id #["index","sel.first"]) == "1.8")
  search id
  check "GUI search wraps" ((← textCall id #["index","sel.first"]) == "1.0")
  replaceMatches id true
  check "GUI replace all" ((← contents id) == "three two three\nshort\nlast")
  dispatch id "undo" #["0"]
  check "GUI replace all is one undo" ((← contents id) == "one two one\nshort\nlast")
  splitPane id
  check "GUI split shares document" ((← contents id) == "one two one\nshort\nlast")
  textCmd id #["insert","end-1c","!"]
  let panes := (← getWindow id).panes
  check "GUI peer edits visible in both panes" ((← tk #[panes[0]!,"get","1.0","end-1c"]) == (← contents id))
  closePane id
  check "GUI close pane keeps text" ((← contents id).endsWith "last!" && (← getWindow id).panes.size == 1)
  install id {text:="abc\ndef\nghi"}
  textCmd id #["mark","set","insert","1.1"]
  selectTo id "3.2" true
  check "GUI rectangular selection" ((← selected id) == "b\ne\nh")
  insertText id "X"
  check "GUI rectangular replacement" ((← contents id) == "aXc\ndXf\ngXi")
  install id {text:="a\nb"}
  textCmd id #["mark","set","insert","1.1"]
  pasteColumn id "XY\nZ\n!"
  check "GUI column paste pads rows" ((← contents id) == "aXY\nbZ\n !")
  install id {text:="abc"}
  dispatch id "toggle_record" #[]
  cmd #["editor",id,"insert_text","X"]
  dispatch id "toggle_record" #[]
  dispatch id "replay" #[]
  for _ in [0:10] do IO.sleep 5; cmd #["update"]
  check "GUI Lean callback and macro replay" ((← contents id) == "XXabc")
  install id {text:="input"}
  dispatch id "select_all" #[]
  startShell id "tr a-z A-Z" true false
  for _ in [0:200] do
    if (← getWindow id).job.isNone then break
    IO.sleep 10; cmd #["update"]
  check "GUI asynchronous shell filter" ((← contents id) == "INPUT" && (← getWindow id).job.isNone)
  closeWindow id
  IO.println s!"{← testsPassed.get} GUI tests passed."

def main (args : List String) : IO UInt32 := do
  if args.contains "--help" then
    IO.println "EditorLean 1.0.4 — native Lean text editor\nUsage: EditorLean [UTF-8 files…]\n       EditorLean --self-test\n       EditorLean --gui-self-test"
    return 0
  if args.contains "--version" then IO.println s!"EditorLean 1.0.4 (Lean 4.35.0-rc3 → C → {System.Platform.target}; Tcl/Tk 9.0.4)"; return 0
  if args.contains "--self-test" then selfTests; return 0
  if args.contains "--gui-self-test" then guiTests; return 0
  tkInit true
  cmd #["wm","withdraw","."]
  let id ← newWindow
  if onMac then
    script "proc ::tk::mac::Quit {} {editor __app quit_all}"
    script "proc ::tk::mac::OpenDocument {args} {foreach path $args {editor __app open $path}}"
  for path in args do
    if !path.startsWith "-psn_" then
      try discard <| openFile id path catch e => alert id "Cannot open file" (toString e)
  tkLoop
  return 0

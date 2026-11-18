import EditorLean
import Init.Data.String.Lemmas
import Init.Data.ByteArray.Lemmas

/- Proofs about the actual imported editor. No application code is duplicated
   for encoding/slicing. checkedSave names the existing post-read save body;
   saveDocument_decomposition proves the connection definitionally. -/
namespace EditorLeanProofs

private theorem byteArray_beq_iff (a b : ByteArray) : (a == b) = true ↔ a = b := by
  change (a.data == b.data) = true ↔ a = b
  simp [ByteArray.ext_iff]

local instance : LawfulBEq ByteArray where
  eq_of_beq := fun h => (byteArray_beq_iff _ _).mp h
  rfl := (byteArray_beq_iff _ _).mpr rfl

-- P1: exact preservation, independently of encoding, size, or line endings.
theorem unchanged_bytes (doc : Document) (raw : ByteArray)
    (h : doc.original = some raw) : encodeDocument doc doc.text = raw := by
  simp [encodeDocument, h]

theorem unchanged_without_original (doc : Document)
    (h : doc.original = none) : encodeDocument doc doc.text = doc.text.toUTF8 := by
  simp [encodeDocument, h]

-- P2: the policy and post-read save body are definitionally the application's.
def expectedBytes (doc : Document) (path : String) : Option ByteArray :=
  if path == doc.path then doc.original else none

def saveConflict (doc : Document) (path : String)
    (existing : Option ByteArray) (overwrite : Bool) : Bool :=
  !overwrite && existing != expectedBytes doc path

def checkedSave (doc : Document) (text path : String)
    (existing : Option ByteArray) (overwrite : Bool) : IO Document := do
  if saveConflict doc path existing overwrite then
    throw <| IO.userError "CONFLICT: file changed on disk or destination already exists."
  let bytes := encodeDocument doc text
  atomicWrite path bytes
  return {doc with path,text,original:=some bytes}

theorem saveDocument_decomposition (doc : Document) (text path : String) (overwrite : Bool) :
    saveDocument doc text path overwrite = (do
      let path ← canonical path
      let existing ← readOptional path
      checkedSave doc text path existing overwrite) := by
  rfl

theorem conflict_iff (doc : Document) (path : String)
    (existing : Option ByteArray) (overwrite : Bool) :
    saveConflict doc path existing overwrite = true ↔
      overwrite = false ∧ existing ≠ expectedBytes doc path := by
  cases overwrite <;> simp [saveConflict]

theorem same_path_conflict_iff (doc : Document) (existing : Option ByteArray) :
    saveConflict doc doc.path existing false = true ↔ existing ≠ doc.original := by
  simp [conflict_iff, expectedBytes]

theorem save_as_existing_conflicts (doc : Document) (path : String) (raw : ByteArray)
    (hpath : path ≠ doc.path) : saveConflict doc path (some raw) false = true := by
  simp [saveConflict, expectedBytes, hpath]

theorem deleted_file_conflicts (doc : Document) (raw : ByteArray)
    (horiginal : doc.original = some raw) : saveConflict doc doc.path none false = true := by
  simp [saveConflict, expectedBytes, horiginal]

theorem new_file_allowed (doc : Document) (horiginal : doc.original = none) :
    saveConflict doc doc.path none false = false := by
  simp [saveConflict, expectedBytes, horiginal]

theorem explicit_overwrite_allowed (doc : Document) (path : String) (existing : Option ByteArray) :
    saveConflict doc path existing true = false := by
  simp [saveConflict]

theorem rejected_save_is_error (doc : Document) (text path : String)
    (existing : Option ByteArray) (overwrite : Bool)
    (h : saveConflict doc path existing overwrite = true) :
    checkedSave doc text path existing overwrite =
      (throw (IO.userError "CONFLICT: file changed on disk or destination already exists.") : IO Document) := by
  simp [checkedSave, h]
  rfl

-- P3: the changed-document branch emits a real UTF-8 BOM prefix.
theorem changed_bom_encoding (doc : Document) (text : String)
    (htext : text ≠ doc.text) (hbom : doc.bom = true) :
    encodeDocument doc text =
      ByteArray.mk #[239,187,191] ++ (text.replace "\n" doc.newline).toUTF8 := by
  simp [encodeDocument, htext, hbom, String.toByteArray_append]
  rfl

theorem changed_no_bom_encoding (doc : Document) (text : String)
    (htext : text ≠ doc.text) (hbom : doc.bom = false) :
    encodeDocument doc text = (text.replace "\n" doc.newline).toUTF8 := by
  simp [encodeDocument, htext, hbom]

theorem changed_bom_prefix (doc : Document) (text : String)
    (htext : text ≠ doc.text) (hbom : doc.bom = true) :
    (encodeDocument doc text).extract 0 3 = ByteArray.mk #[239,187,191] := by
  rw [changed_bom_encoding doc text htext hbom]
  exact ByteArray.extract_append_eq_left (by rfl)

theorem changed_bom_size (doc : Document) (text : String)
    (htext : text ≠ doc.text) (hbom : doc.bom = true) :
    (encodeDocument doc text).size = 3 + (text.replace "\n" doc.newline).toUTF8.size := by
  rw [changed_bom_encoding doc text htext hbom, ByteArray.size_append]
  rfl

-- P4: the decoder primitive rejects all invalid UTF-8, not just FF FE.
-- These do not yet prove BOM stripping or newline normalization in decodeDocument.
theorem utf8_roundtrip (text : String) :
    String.fromUTF8? text.toUTF8 = some text := by
  simp [String.fromUTF8?, String.isValidUTF8, String.fromUTF8]

theorem invalid_utf8_rejected (bytes : ByteArray) (h : ¬ bytes.IsValidUTF8) :
    String.fromUTF8? bytes = none := by
  simp [String.fromUTF8?, h]

theorem absent_document_is_empty (path : String) :
    decodeDocument path none = pure ({path} : Document) := by
  rfl

-- Supporting navigation/editing bounds; these are not whole word-navigation proofs.
theorem slice_length (text : String) (first last : Nat) :
    (charSlice text first last).length = min (last-first) (text.length-first) := by
  simp [charSlice, String.length_toList]

theorem slice_bounded (text : String) (first last : Nat) :
    (charSlice text first last).length ≤ last-first := by
  rw [slice_length]
  exact Nat.min_le_left _ _

theorem slice_no_growth (text : String) (first last : Nat) :
    (charSlice text first last).length ≤ text.length := by
  rw [slice_length]
  omega

theorem slice_reversed_empty (text : String) (first last : Nat) (h : last ≤ first) :
    charSlice text first last = "" := by
  simp [charSlice, Nat.sub_eq_zero_of_le h]

end EditorLeanProofs

-- Dependency audit: standard logical axioms are reported, not hidden.
#print axioms EditorLeanProofs.unchanged_bytes
#print axioms EditorLeanProofs.unchanged_without_original
#print axioms EditorLeanProofs.saveDocument_decomposition
#print axioms EditorLeanProofs.conflict_iff
#print axioms EditorLeanProofs.same_path_conflict_iff
#print axioms EditorLeanProofs.save_as_existing_conflicts
#print axioms EditorLeanProofs.deleted_file_conflicts
#print axioms EditorLeanProofs.new_file_allowed
#print axioms EditorLeanProofs.explicit_overwrite_allowed
#print axioms EditorLeanProofs.rejected_save_is_error
#print axioms EditorLeanProofs.changed_bom_encoding
#print axioms EditorLeanProofs.changed_no_bom_encoding
#print axioms EditorLeanProofs.changed_bom_prefix
#print axioms EditorLeanProofs.changed_bom_size
#print axioms EditorLeanProofs.utf8_roundtrip
#print axioms EditorLeanProofs.invalid_utf8_rejected
#print axioms EditorLeanProofs.absent_document_is_empty
#print axioms EditorLeanProofs.slice_length
#print axioms EditorLeanProofs.slice_bounded
#print axioms EditorLeanProofs.slice_no_growth
#print axioms EditorLeanProofs.slice_reversed_empty

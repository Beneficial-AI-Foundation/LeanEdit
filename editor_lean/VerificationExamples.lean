import EditorLean

-- Evaluated counterexamples, NOT universal theorems and NOT proof premises.
#eval indentText "\tx" 0
#eval (fillText (String.ofList (List.replicate 81 'x'))).length

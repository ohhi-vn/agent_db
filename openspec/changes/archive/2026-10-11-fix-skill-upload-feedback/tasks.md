# Tasks

## 1. Upload feedback on the skills form

- [x] 1.1 Bind `phx-change="validate"` on the import form with a render-only validate event and enable `auto_upload` on both upload configs; verify by selecting files and seeing entries/progress/errors before submit, and by submit importing exactly as today.
- [x] 1.2 Add regression tests (selection lists entries pre-submit; submit-after-select imports; error entry reported) and run adjacent suites + `openspec validate fix-skill-upload-feedback`; verify by green suites and valid change.

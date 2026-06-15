# AND-5 — TextInput controlled-input parity

| | |
|---|---|
| **Track** | android |
| **Status** | todo |
| **Effort** | ~1.5 engineer-weeks |
| **Classification** | DEPENDENT — blocked until its prerequisites land |
| **Depends on** | AND-4 (todo) |
| **Open blockers** | AND-4 (todo) |
| **Source plan** | plans/10-competitor-master-plan.md |

Preserve caret on controlled setValue (diff offset, port RN's setText-with-selection-restore) and add maxLength/returnKeyType/autoCapitalize/selection + multiline grow via Yoga dirty.

**Notes:** setValueControlled forces caret to end (corrupts mid-string edit) today. A form is the core of a real app.

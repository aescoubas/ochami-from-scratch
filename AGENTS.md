# OpenChami Agent Guidelines

## Context
*   **Core Logic:** `src/` (or `cmd/`, `pkg/` depending on language)
*   **Docs:** `README.md`, `ROADMAP.md`

## Mandates
1.  **Roadmap Driven:** Always check `ROADMAP.md` before starting work. Mark tasks as `[x]` only after verification.
2.  **Test First:** Create/Update tests before implementing features.
3.  **Style:** Follow the existing coding style (check `.editorconfig`, linters).
4.  **Operational Safety:**
    *   **Non-Interactive:** Use flags to suppress prompts (e.g., `apt-get -y`, `npm install --yes`).
    *   **No Watch Modes:** Never run commands that block forever (e.g., `npm start`) unless explicitly requested as a background daemon.
5.  **Git:**
    *   **Commit Message Standard:** Use Conventional Commits (`type(scope): description`).
        *   Types: `feat`, `fix`, `docs`, `style`, `refactor`, `test`, `chore`.
        *   Example: `feat(auth): implement JWT token rotation`
    *   **Descriptive:** The message must clearly explain *what* changed and *why*. Avoid vague messages like "fix".
    *   Never commit broken code.

## Verification
*   Always run the build/test suite before finishing a turn.
*   Command: `make test` (or `npm test`, `go test ./...`)

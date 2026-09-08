# Replacement instructions

1. Replace the repository-root `README.md` with the provided `README.md`.
2. Add `docs/technical-architecture-and-validation.md`.
3. Do not copy any customer-specific incident report or production evidence into the generic repository.
4. Run the repository sanitizer.
5. Regenerate `PACKAGE-SHA256.txt`.
6. Run the Pester suite and confirm 35/35 still passes.
7. Review `git diff` before committing.

Suggested commit message:

    Expand README and add technical architecture validation report

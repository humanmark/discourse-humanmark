# Discourse Humanmark Plugin Development Commands

# Default command - show available commands
default:
    @just --list

# Install all dependencies
install:
    npm install
    bundle install

# Run all linters
lint: lint-js lint-scss lint-ruby

# Lint JavaScript files
lint-js:
    npm run lint:js

# Lint SCSS files
lint-scss:
    npm run lint:scss

# Lint Ruby files
lint-ruby:
    npm run lint:ruby

# Fix all auto-fixable linting issues
lint-fix: lint-js-fix lint-scss-fix lint-ruby-fix

# Fix JavaScript linting issues
lint-js-fix:
    npm run lint:js:fix

# Fix SCSS linting issues
lint-scss-fix:
    npm run lint:scss:fix

# Fix Ruby linting issues
lint-ruby-fix:
    npm run lint:ruby:fix

# Format all code
format:
    npm run format

# Format JavaScript files
format-js:
    npm run format:js

# Format SCSS files
format-scss:
    npm run format:scss

# Check code formatting without changing files
format-check:
    npm run format:check

# Run all checks (lint + format)
check:
    npm run check

# Clean up generated files
clean:
    rm -rf node_modules
    rm -rf vendor
    rm -f Gemfile.lock
    rm -f package-lock.json

# Run all tests
test:
    @echo "⚠️  Note: Full testing requires installation in a Discourse instance"
    @echo "See DEVELOPMENT.md for complete test setup instructions"
    @echo ""
    @echo "For testing in a Discourse installation, run:"
    @echo "  cd /path/to/discourse"
    @echo "  bundle exec rake plugin:spec[discourse-humanmark]"

# Run backend tests (requires Discourse installation)
test-backend:
    @echo "Run from Discourse root: bundle exec rake plugin:spec[discourse-humanmark]"

# Run frontend tests (requires Discourse installation)
test-frontend:
    @echo "Run from Discourse root: bundle exec rake plugin:qunit[discourse-humanmark]"

# Validate test files syntax
test-validate:
    @echo "Validating test file syntax..."
    @for file in spec/**/*.rb; do \
        ruby -c "$$file" > /dev/null 2>&1 && echo "✓ $$file" || echo "✗ $$file"; \
    done

# Watch files for changes and run linters
watch:
    @echo "Watching for changes in assets/, lib/, and app/..."
    @echo "Press Ctrl+C to stop"
    watchexec -e js,scss,rb -w assets -w lib -w app -- just lint

# Run a specific npm script
npm script:
    npm run {{script}}

# Run a specific bundle command
bundle *args:
    bundle {{args}}

# Start a development console
console:
    @echo "Starting Rails console in Discourse..."
    @echo "Make sure you're in the Discourse root directory"
    @echo "Run: rails c"

# Update dependencies
update:
    npm update
    bundle update

# Check for outdated dependencies
outdated:
    @echo "=== NPM packages ==="
    npm outdated || true
    @echo ""
    @echo "=== Ruby gems ==="
    bundle outdated || true

# Run security audit
audit:
    @echo "=== NPM security audit ==="
    npm audit || true
    @echo ""
    @echo "=== Bundle security audit ==="
    bundle audit || true

# Initialize git hooks
init-hooks:
    npx husky install .husky

# Run pre-commit checks
pre-commit:
    npm run pre-commit

# Quick setup for new developers
setup: install init-hooks
    @echo "✅ Development environment ready!"
    @echo "Run 'just' to see available commands"

# Fix common issues
doctor:
    @echo "🏥 Running diagnostics..."
    @echo ""
    @echo "Checking Node.js version..."
    @node --version
    @echo ""
    @echo "Checking Ruby version..."
    @ruby --version
    @echo ""
    @echo "Checking for required commands..."
    @command -v npm >/dev/null && echo "✓ npm found" || echo "✗ npm not found"
    @command -v bundle >/dev/null && echo "✓ bundle found" || echo "✗ bundle not found"
    @command -v eslint >/dev/null && echo "✓ eslint found" || echo "✗ eslint not found (run 'just install')"
    @command -v rubocop >/dev/null && echo "✓ rubocop found" || echo "✗ rubocop not found (run 'just install')"
    @echo ""
    @echo "Checking plugin structure..."
    @test -f plugin.rb && echo "✓ plugin.rb found" || echo "✗ plugin.rb not found"
    @test -d config && echo "✓ config/ directory found" || echo "✗ config/ directory not found"
    @test -d lib && echo "✓ lib/ directory found" || echo "✗ lib/ directory not found"
    @test -d assets && echo "✓ assets/ directory found" || echo "✗ assets/ directory not found"
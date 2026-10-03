const js = require('@eslint/js');

const nodeGlobals = {
  require: 'readonly', module: 'writable', exports: 'writable', process: 'readonly',
  console: 'readonly', __dirname: 'readonly', __filename: 'readonly', Buffer: 'readonly',
  setTimeout: 'readonly', clearTimeout: 'readonly', setInterval: 'readonly', clearInterval: 'readonly',
  fetch: 'readonly', URL: 'readonly',
};
const jestGlobals = {
  describe: 'readonly', test: 'readonly', it: 'readonly', expect: 'readonly', jest: 'readonly',
  beforeAll: 'readonly', afterAll: 'readonly', beforeEach: 'readonly', afterEach: 'readonly',
};

module.exports = [
  { ignores: ['node_modules/**', 'supabase/**'] },
  js.configs.recommended,
  {
    files: ['**/*.js'],
    languageOptions: { ecmaVersion: 2022, sourceType: 'commonjs', globals: nodeGlobals },
    rules: {
      'no-unused-vars': ['error', { argsIgnorePattern: '^_', caughtErrors: 'none' }],
    },
  },
  {
    // Code navigateur (UMD, aussi chargé par Jest)
    files: ['public/**/*.js'],
    languageOptions: { globals: { ...nodeGlobals, self: 'readonly', window: 'readonly' } },
  },
  {
    files: ['tests/**/*.js'],
    languageOptions: { globals: { ...nodeGlobals, ...jestGlobals } },
  },
];

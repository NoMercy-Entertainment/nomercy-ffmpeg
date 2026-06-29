import antfu from '@antfu/eslint-config';

export default antfu({
	ignores: [
		'dist/**',
		'README.md',
		'eslint.config.js',
	],
	typescript: {
		overrides: {
			'no-nested-ternary': 'error',
			'antfu/top-level-function': 'off',
			'unused-imports/no-unused-vars': 'error',
			'node/prefer-global/process': 'off',
			// dot-notation conflicts with TS noPropertyAccessFromIndexSignature: typed index-signature
			// properties (process.env.*) must use bracket notation; ESLint's autofix would break the build.
			'dot-notation': 'off',
		},
	},
	stylistic: {
		indent: 'tab',
		quotes: 'single',
		semi: true,
	},
});

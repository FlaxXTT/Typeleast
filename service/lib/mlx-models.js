/** Model files pinned to a published revision. No executable code is downloaded. */
const repo = 'mlx-community/Fun-ASR-Nano-2512';
const revision = 'a7bc96fceaafce39ed6748e0c0fa9a9508b67f86';
const id = 'mlx-fun-asr-nano-bf16';
const files = [
  ['config.json', 1706, '4df3d9ff5b222b7a0be5dcf3f815dba995f37c6fbefe387436072303670c0ad8'],
  ['model.safetensors', 1659734710, '2e2ba5e2591f75f63b25ee5b53a895d3cd5afcc642c3db4482d3ee27b0a00449'],
  ['Qwen3-0.6B/config.json', 726, '660db3b73d788119c04535e48cf9be5f55bc3100841a718637ae695b442f27dd'],
  ['Qwen3-0.6B/generation_config.json', 239, '2325da0f15bb848e018c5ae071b7943332e9f871d6b60e2ed22ca97d4cb993d2'],
  ['Qwen3-0.6B/merges.txt', 1671853, '8831e4f1a044471340f7c0a83d7bd71306a5b867e95fd870f74d0c5308a904d5'],
  ['Qwen3-0.6B/tokenizer.json', 11422654, 'aeb13307a71acd8fe81861d94ad54ab689df773318809eed3cbe794b4492dae4'],
  ['Qwen3-0.6B/tokenizer_config.json', 9732, 'd5d09f07b48c3086c508b30d1c9114bd1189145b74e982a265350c923acd8101'],
  ['Qwen3-0.6B/vocab.json', 2776833, 'ca10d7e9fb3ed18575dd1e277a2579c16d108e32f27439684afa0e10b1440910'],
].map(([file, size, sha256]) => ({ id: `${id}/${file}`, path: [id, ...file.split('/')], repo, revision, file, size, sha256 }));

export const MLX_DEFAULT_MODEL_ID = id;
export const MLX_MODELS = [{
  id, name: 'Fun-ASR-Nano (MLX BF16)', sourceUrl: `https://huggingface.co/${repo}`,
  source: 'https://github.com/FunAudioLLM/Fun-ASR', license: 'Apache-2.0',
  // Fun-ASR supports language hints but does not report an independently
  // detected language. An explicit choice is the user's declaration.
  engine: 'mlx', precision: 'bf16', languages: ['auto', 'zh', 'en', 'ja'], canSetLanguage: true,
  modelBytes: files.reduce((total, file) => total + file.size, 0), files,
}];

// Only expose a candidate after it has passed a real load and recognition test.
// The official tokenizer is pinned independently: mlx-audio-swift otherwise
// generates a local tokenizer.json that is not covered by the model inventory.
const qwenCommon = [
  ['chat_template.json', 1161, '75a8cfca24f00de72d796fbfed6858fc9614ef3dabd8696684cc3bc03a9c58ff'],
  ['generation_config.json', 142, '1da527824d81e07118facff437e03f2e24a23311e3bdeb2368973fe77e5f275c'],
  ['merges.txt', 1671853, '8831e4f1a044471340f7c0a83d7bd71306a5b867e95fd870f74d0c5308a904d5'],
  ['preprocessor_config.json', 330, '45e120a4eda2c20c5d7f2ea9354e63536bf35e27aa573fb7cdf78017b378770d'],
  ['tokenizer_config.json', 12487, '4942d005604266809309cabc9f4e9cb89ce855d59b14681fdc0e1cc62ea26c4c'],
  ['vocab.json', 2776833, 'ca10d7e9fb3ed18575dd1e277a2579c16d108e32f27439684afa0e10b1440910'],
];
function qwenModel(size, revision, tokenizerRevision, specific) {
  const modelId = `mlx-qwen3-asr-${size.toLowerCase()}-bf16`;
  const modelRepo = `mlx-community/Qwen3-ASR-${size}-bf16`;
  const modelFiles = [...qwenCommon, ...specific].map(([file, fileSize, sha256]) => ({
    id: `${modelId}/${file}`, path: [modelId, file], repo: modelRepo, revision,
    file, size: fileSize, sha256,
  }));
  modelFiles.push({
    id: `${modelId}/tokenizer.json`, path: [modelId, 'tokenizer.json'],
    repo: `Qwen/Qwen3-ASR-${size}-hf`, revision: tokenizerRevision,
    file: 'tokenizer.json', size: 11429653,
    sha256: 'fe1fad59be22a41ee293363fcf95fdedbc7c93f3b49270b1d2e18bd1399a7a05',
  });
  return {
    id: modelId, name: `Qwen3-ASR-${size} (MLX BF16)`,
    sourceUrl: `https://huggingface.co/${modelRepo}`,
    source: 'https://github.com/QwenLM/Qwen3-ASR', license: 'Apache-2.0',
    engine: 'mlx', precision: 'bf16', languages: ['auto', 'zh', 'en', 'ja', 'ko', 'yue'], canSetLanguage: true,
    modelBytes: modelFiles.reduce((total, file) => total + file.size, 0), files: modelFiles,
  };
}

export const MLX_QWEN_MODELS = [
  qwenModel('0.6B', 'eae2b51f96265328f1e7beced788adb0e4536f92',
    '7f1569a48a89f3e3f4dc3a5c9d28bddd903bc76c', [
      ['config.json', 6982, 'dae1fbfa8b858aceefe5afcc7ecc9184e4a6045bc4a1bca8a41834724f490874'],
      ['model.safetensors', 1564921888, 'a6e635fd9c8dfd5cdd7465db9bd8c947ab30737b90b83b6b09c304e836bb8a7f'],
      ['model.safetensors.index.json', 44231, '4722310af2af946f54385d2aed98485961f5af0c0a340390ccf3c95f475db6a4'],
    ]),
  qwenModel('1.7B', 'e1f6c266914abc5a46e8756e02580f834a6cf8a7',
    'bcd2b5b7f32b480ab5790554cfa8347f246a14f3', [
      ['config.json', 6983, '62fe9a2ba2de536820229e126fdfb35f9910b9a337dc46d3737c3b1ac0a9caa9'],
      ['model.safetensors', 4076186653, '2f080a3b769ae469aeaaa2dcb9e13a94141e54c9e6d5a7aa63392e0dc5a51789'],
      ['model.safetensors.index.json', 51384, 'a3ee6037ec82e95dc8577216ac84cf0b3c92cfefc099cf20b2296571f2fb3fc0'],
    ]),
];

// User-installed candidate: 8-bit recognition on this Mac has not yet been tested.
const qwen8Files = [
  {
    "id": "mlx-qwen3-asr-1.7b-8bit/chat_template.json",
    "path": [
      "mlx-qwen3-asr-1.7b-8bit",
      "chat_template.json"
    ],
    "repo": "mlx-community/Qwen3-ASR-1.7B-8bit",
    "revision": "a8379a2e2f9e313c9292cdf1af4055ab56d50d55",
    "file": "chat_template.json",
    "size": 1161,
    "sha256": "75a8cfca24f00de72d796fbfed6858fc9614ef3dabd8696684cc3bc03a9c58ff"
  },
  {
    "id": "mlx-qwen3-asr-1.7b-8bit/config.json",
    "path": [
      "mlx-qwen3-asr-1.7b-8bit",
      "config.json"
    ],
    "repo": "mlx-community/Qwen3-ASR-1.7B-8bit",
    "revision": "a8379a2e2f9e313c9292cdf1af4055ab56d50d55",
    "file": "config.json",
    "size": 7188,
    "sha256": "1b76b3b6c655fc54595da025f7a96474ad9fa86363303fbdd61a7d8483ccfaf7"
  },
  {
    "id": "mlx-qwen3-asr-1.7b-8bit/generation_config.json",
    "path": [
      "mlx-qwen3-asr-1.7b-8bit",
      "generation_config.json"
    ],
    "repo": "mlx-community/Qwen3-ASR-1.7B-8bit",
    "revision": "a8379a2e2f9e313c9292cdf1af4055ab56d50d55",
    "file": "generation_config.json",
    "size": 142,
    "sha256": "1da527824d81e07118facff437e03f2e24a23311e3bdeb2368973fe77e5f275c"
  },
  {
    "id": "mlx-qwen3-asr-1.7b-8bit/merges.txt",
    "path": [
      "mlx-qwen3-asr-1.7b-8bit",
      "merges.txt"
    ],
    "repo": "mlx-community/Qwen3-ASR-1.7B-8bit",
    "revision": "a8379a2e2f9e313c9292cdf1af4055ab56d50d55",
    "file": "merges.txt",
    "size": 1671853,
    "sha256": "8831e4f1a044471340f7c0a83d7bd71306a5b867e95fd870f74d0c5308a904d5"
  },
  {
    "id": "mlx-qwen3-asr-1.7b-8bit/model.safetensors",
    "path": [
      "mlx-qwen3-asr-1.7b-8bit",
      "model.safetensors"
    ],
    "repo": "mlx-community/Qwen3-ASR-1.7B-8bit",
    "revision": "a8379a2e2f9e313c9292cdf1af4055ab56d50d55",
    "file": "model.safetensors",
    "size": 2463307541,
    "sha256": "bf304b009cc7eca79283056f787b44c952d24ac22cec787b39732bba3c23c13c"
  },
  {
    "id": "mlx-qwen3-asr-1.7b-8bit/model.safetensors.index.json",
    "path": [
      "mlx-qwen3-asr-1.7b-8bit",
      "model.safetensors.index.json"
    ],
    "repo": "mlx-community/Qwen3-ASR-1.7B-8bit",
    "revision": "a8379a2e2f9e313c9292cdf1af4055ab56d50d55",
    "file": "model.safetensors.index.json",
    "size": 78968,
    "sha256": "0a5d0ec11188602242ff81a9969883d0fdeb98cd5d85cd1413089d897c201af5"
  },
  {
    "id": "mlx-qwen3-asr-1.7b-8bit/preprocessor_config.json",
    "path": [
      "mlx-qwen3-asr-1.7b-8bit",
      "preprocessor_config.json"
    ],
    "repo": "mlx-community/Qwen3-ASR-1.7B-8bit",
    "revision": "a8379a2e2f9e313c9292cdf1af4055ab56d50d55",
    "file": "preprocessor_config.json",
    "size": 330,
    "sha256": "45e120a4eda2c20c5d7f2ea9354e63536bf35e27aa573fb7cdf78017b378770d"
  },
  {
    "id": "mlx-qwen3-asr-1.7b-8bit/tokenizer_config.json",
    "path": [
      "mlx-qwen3-asr-1.7b-8bit",
      "tokenizer_config.json"
    ],
    "repo": "mlx-community/Qwen3-ASR-1.7B-8bit",
    "revision": "a8379a2e2f9e313c9292cdf1af4055ab56d50d55",
    "file": "tokenizer_config.json",
    "size": 12487,
    "sha256": "4942d005604266809309cabc9f4e9cb89ce855d59b14681fdc0e1cc62ea26c4c"
  },
  {
    "id": "mlx-qwen3-asr-1.7b-8bit/vocab.json",
    "path": [
      "mlx-qwen3-asr-1.7b-8bit",
      "vocab.json"
    ],
    "repo": "mlx-community/Qwen3-ASR-1.7B-8bit",
    "revision": "a8379a2e2f9e313c9292cdf1af4055ab56d50d55",
    "file": "vocab.json",
    "size": 2776833,
    "sha256": "ca10d7e9fb3ed18575dd1e277a2579c16d108e32f27439684afa0e10b1440910"
  },
  {
    "id": "mlx-qwen3-asr-1.7b-8bit/tokenizer.json",
    "path": [
      "mlx-qwen3-asr-1.7b-8bit",
      "tokenizer.json"
    ],
    "repo": "Qwen/Qwen3-ASR-1.7B-hf",
    "revision": "bcd2b5b7f32b480ab5790554cfa8347f246a14f3",
    "file": "tokenizer.json",
    "size": 11429653,
    "sha256": "fe1fad59be22a41ee293363fcf95fdedbc7c93f3b49270b1d2e18bd1399a7a05"
  }
];
MLX_MODELS.push({
  id: 'mlx-qwen3-asr-1.7b-8bit', name: 'Qwen3-ASR-1.7B (MLX 8-bit)',
  sourceUrl: 'https://huggingface.co/mlx-community/Qwen3-ASR-1.7B-8bit',
  source: 'https://github.com/QwenLM/Qwen3-ASR', license: 'Apache-2.0',
  engine: 'mlx', precision: '8-bit', languages: ['auto', 'zh', 'en', 'ja', 'ko', 'yue'], canSetLanguage: true,
  modelBytes: qwen8Files.reduce((total, file) => total + file.size, 0), files: qwen8Files,
});

// Both models passed isolated load and multilingual recognition with the worker.
MLX_MODELS.push(...MLX_QWEN_MODELS);

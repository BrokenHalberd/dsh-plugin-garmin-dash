/**
 * 本地大模型配置与连通性测试（OpenAI 兼容接口）
 * 配置存设备 preferences，不经过任何服务器。
 */
import { http } from '@kit.NetworkKit';
import { DeviceStore } from './DeviceStore';

interface ModelEntry {
  id?: string;
}

interface ModelsResp {
  data?: ModelEntry[];
}

export interface LlmConfig {
  baseUrl: string;
  apiKey: string;
  model: string;
}

export class LocalLlm {
  /** 常见预设，便于用户一键填入 */
  static readonly PRESETS: string[] = [
    'https://api.deepseek.com/v1',
    'https://api.openai.com/v1',
    'https://api.moonshot.cn/v1',
    'https://dashscope.aliyuncs.com/compatible-mode/v1'
  ];

  static config(): LlmConfig {
    return {
      baseUrl: DeviceStore.getLlmBaseUrl(),
      apiKey: DeviceStore.getLlmKey(),
      model: DeviceStore.getLlmModel()
    };
  }

  static save(c: LlmConfig): void {
    DeviceStore.setLlmBaseUrl(c.baseUrl);
    DeviceStore.setLlmKey(c.apiKey);
    DeviceStore.setLlmModel(c.model);
  }

  /** 是否已配置完整（缺一项即视为未配置） */
  static ready(): boolean {
    const c = LocalLlm.config();
    return c.baseUrl.length > 0 && c.apiKey.length > 0 && c.model.length > 0;
  }


  /**
   * 导出为可读配置串：
   *   garminlocal-llm-v1|u=<baseUrl>|k=<apiKey>|m=<model>
   * 用于换证书/重装后恢复（注意：串里含明文 Key，请勿发给他人）
   */
  static exportCode(c: LlmConfig): string {
    const esc = (s: string): string => s.replace(/\|/g, '%7C').replace(/\n/g, '');
    return 'garminlocal-llm-v1|u=' + esc(c.baseUrl) + '|k=' + esc(c.apiKey) + '|m=' + esc(c.model);
  }

  /** 解析导入：格式不符则抛出可读错误 */
  static importCode(text: string): LlmConfig {
    const t = text.trim();
    if (!t.startsWith('garminlocal-llm-v1|')) {
      throw new Error('不是本应用的配置串（应以 garminlocal-llm-v1| 开头）');
    }
    const parts: string[] = t.split('|');
    let u = '';
    let k = '';
    let m = '';
    for (let i = 1; i < parts.length; i++) {
      const seg = parts[i];
      if (seg.startsWith('u=')) {
        u = seg.substring(2).replace(/%7C/g, '|');
      } else if (seg.startsWith('k=')) {
        k = seg.substring(2).replace(/%7C/g, '|');
      } else if (seg.startsWith('m=')) {
        m = seg.substring(2).replace(/%7C/g, '|');
      }
    }
    if (u.length === 0 || k.length === 0) {
      throw new Error('配置串缺少接口地址或 API Key');
    }
    return { baseUrl: u, apiKey: k, model: m.length > 0 ? m : 'deepseek-chat' };
  }


  /**
   * 拉取可用模型列表（GET {base}/models）。
   * 兼容 OpenAI 标准 { data: [{ id }] }；也兼容少数返回 { models: [...] } 的实现。
   */
  static async listModels(c: LlmConfig): Promise<string[]> {
    if (c.baseUrl.length === 0) {
      throw new Error('请先填写接口地址');
    }
    if (c.apiKey.length === 0) {
      throw new Error('请先填写 API Key');
    }
    let base = c.baseUrl.trim();
    while (base.endsWith('/')) {
      base = base.substring(0, base.length - 1);
    }
    const req = http.createHttp();
    try {
      const res = await req.request(base + '/models', {
        method: http.RequestMethod.GET,
        usingProtocol: http.HttpProtocol.HTTP1_1,
        header: {
          'Authorization': 'Bearer ' + c.apiKey,
          'Content-Type': 'application/json'
        } as Record<string, string>,
        connectTimeout: 15000,
        readTimeout: 30000,
        expectDataType: http.HttpDataType.STRING
      });
      if (res.responseCode === 401) {
        throw new Error('API Key 无效（401）');
      }
      if (res.responseCode !== 200) {
        throw new Error('HTTP ' + res.responseCode);
      }
      const body = JSON.parse(res.result as string) as ModelsResp;
      const out: string[] = [];
      const arr = body.data;
      if (arr !== undefined && arr !== null) {
        for (let i = 0; i < arr.length; i++) {
          const id = arr[i].id;
          if (id !== undefined && id !== null && id.length > 0) {
            out.push(id);
          }
        }
      }
      out.sort();
      return out;
    } finally {
      req.destroy();
    }
  }

  /** 测试连接：请求 {base}/models，200 视为可用 */
  static async test(c: LlmConfig): Promise<string> {
    if (c.baseUrl.length === 0) {
      throw new Error('请先填写接口地址');
    }
    if (c.apiKey.length === 0) {
      throw new Error('请先填写 API Key');
    }
    let base = c.baseUrl.trim();
    while (base.endsWith('/')) {
      base = base.substring(0, base.length - 1);
    }
    const req = http.createHttp();
    try {
      const res = await req.request(base + '/models', {
        method: http.RequestMethod.GET,
        usingProtocol: http.HttpProtocol.HTTP1_1,
        header: {
          'Authorization': 'Bearer ' + c.apiKey,
          'Content-Type': 'application/json'
        } as Record<string, string>,
        connectTimeout: 15000,
        readTimeout: 30000,
        expectDataType: http.HttpDataType.STRING
      });
      if (res.responseCode === 200) {
        const txt = res.result as string;
        const n = (txt.match(/"id"\s*:/g) ?? []).length;
        return '连接成功 ✓' + (n > 0 ? ('（可用模型 ' + n + ' 个）') : '');
      }
      if (res.responseCode === 401) {
        throw new Error('API Key 无效（401）');
      }
      throw new Error('HTTP ' + res.responseCode);
    } finally {
      req.destroy();
    }
  }
}
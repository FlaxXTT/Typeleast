/** Optional extension boundary. The core service only calls the methods on this object. */

export class PluginRuntime {
  constructor(store) {
    this.store = store;
  }

  referenceData() {
    const terms=[], aliases=[];
    for(const plugin of this.store.plugins?.values?.() ?? []) {
      if(!this.store.state.plugins[plugin.id]?.enabled || plugin.type!=='dictionary')continue;
      for(const term of plugin.terms)terms.push({word:term,sourceId:plugin.id,label:plugin.name});
      for(const alias of plugin.aliases??[])aliases.push({...alias,sourceId:plugin.id,label:plugin.name});
    }
    return {terms,aliases,style:null};
  }

  state() {
    return { plugins: this.store.list(), style: null, problems: this.store.problems ?? [] };
  }

  /** Called only after the core HTTP layer has checked Host and bearer token. */
  async handleHttp({ route, req, res, readBody, reply, maxJsonBytes }) {
    const id = /^\/plugins\/([a-z0-9.-]{3,80})$/.exec(route)?.[1];
    if (route === "/plugins" && req.method === "GET") { reply(res, 200, this.state()); return true; }
    if (id && req.method === "PUT") {
      const body = JSON.parse((await readBody(req, maxJsonBytes)).toString("utf8") || "{}") ?? {};
      await this.store.setEnabled(id, body.enabled === true);
      reply(res, 200, this.state());
      return true;
    }
    return false;
  }
}

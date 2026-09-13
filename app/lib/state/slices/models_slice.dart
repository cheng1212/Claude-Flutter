// 模型列表状态切片(优化方案 T4 第二刀):从 ZApp 拆出的领域切片。
// 纯状态 + 拉取规则;跨域依赖由 ZApp 注入,依赖方向:slice 不可反向引用 ZApp。
// - [onChanged]:数据变化后由 ZApp 传入 notifyListeners(UI 仍只监听 ZApp,零改动)
// - [onError]:拉取失败写 ZApp.error(聊天页顶部错误条数据源)
// - [fetchModels]/[fetchModelGroups]:REST 拉取器(ZApp._api 包装)

class ModelsSlice {
  ModelsSlice({
    required this.onChanged,
    required this.onError,
    required this.fetchModels,
    required this.fetchModelGroups,
  });

  final void Function() onChanged;
  final void Function(String message) onError;
  final Future<List<String>> Function() fetchModels;
  final Future<List<Map<String, dynamic>>> Function() fetchModelGroups;

  List<String> models = const [];
  List<Map<String, dynamic>> modelGroups = const [];

  /// 启动/刷新:拉平铺模型 + 分组模型;失败写 error(不抛,保持原 ZApp 语义)。
  Future<void> load() async {
    try {
      models = await fetchModels();
      modelGroups = await fetchModelGroups();
      onChanged();
    } on Object catch (e) {
      onError('$e');
    }
  }

  /// 选择器打开时的兜底重拉,成功后刷新状态。
  Future<List<Map<String, dynamic>>> reloadGroups() async {
    modelGroups = await fetchModelGroups();
    onChanged();
    return modelGroups;
  }
}

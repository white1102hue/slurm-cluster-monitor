enum AppSkin {
  ocean('深海'),
  daylight('纯白'),
  violet('紫夜');

  const AppSkin(this.label);
  final String label;
  static AppSkin parse(String? value) => AppSkin.values.firstWhere(
    (skin) => skin.name == value,
    orElse: () => AppSkin.ocean,
  );
}

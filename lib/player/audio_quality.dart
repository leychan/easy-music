/// 酷狗播放接口接受的音质档位。
enum AudioQuality {
  standard('128', '标准'),
  high('320', '高品'),
  lossless('flac', '无损'),
  hifi('high', 'Hi-Res');

  const AudioQuality(this.apiName, this.label);

  final String apiName;
  final String label;

  static AudioQuality? fromApiName(Object? value) => values
      .where((quality) => quality.apiName == value?.toString())
      .firstOrNull;
}

enum SortOption {
  titleAsc('Título'),
  artistAsc('Artista'),
  dateAddedDesc('Más recientes'),
  durationDesc('Duración');

  const SortOption(this.label);
  final String label;
}

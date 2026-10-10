enum AppRole {
  customer('Customer', 'Browse and buy building supplies', 'customer'),
  dealer('Dealer', 'View dealer pricing and live stock', 'dealer'),
  plumber('Plumber', 'Access your assigned activities', 'plumber'),
  admin('Admin', 'Manage Waytowebs operations', 'admin');

  const AppRole(this.label, this.description, this.apiValue);

  final String label;
  final String description;
  final String apiValue;
}

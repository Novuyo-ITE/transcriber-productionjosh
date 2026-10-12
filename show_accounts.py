import os
import django

# 1. Tell Django where your settings file is located
# Replace 'myproject' with the name of the folder containing your settings.py
os.environ.setdefault('DJANGO_SETTINGS_MODULE', 'myproject.settings')

# 2. Initialize Django
django.setup()

# 3. Now you can safely import and run your database queries
from django.contrib.auth import get_user_model

User = get_user_model()

total_accounts = User.objects.count()
print(f"Total Accounts: {total_accounts}\n")

print(f"{'Username':<20} | {'Password Hash (Encrypted)'}")
print("-" * 60)

for user in User.objects.all():
    print(f"{user.get_username():<20} | {user.password}")

#! bash

pacman -Sy --noconfirm --needed curl tar

rm -rf ~/dotfiles.tar.gz || true
rm -rf ~/dotfiles || true

curl -L https://github.com/fkanzler/dotfiles/archive/refs/heads/main.tar.gz -o ~/dotfiles.tar.gz
tar -xzf ~/dotfiles.tar.gz -C ~/
mv ~/dotfiles-main ~/dotfiles

chmod +x ~/dotfiles/install.sh

~/dotfiles/install.sh

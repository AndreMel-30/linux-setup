# linux-setup

A pair of bash scripts to save how your Linux is set up and put it back after a clean install. It works on Ubuntu and distros based on it (Linux Mint, Pop!_OS, Zorin, elementary...).

It handles:

- apt, Flatpak and Snap packages
- desktop settings (through dconf)
- dotfiles like `.bashrc` and `.gitconfig`
- a few system tweaks (swappiness, TRIM)
- anything else you want, through your own scripts ("hooks")

The scripts are the same for everyone. Your own data lives in a **profile**, a folder inside `profiles/`.

## How to use it

First fork this repo on GitHub (or copy it into a private repo), so you have your own copy to push your profile to. In the commands below, replace `AndreMel-30` with your GitHub username.

On the system you have now, before reinstalling:

```bash
git clone https://github.com/AndreMel-30/linux-setup.git
cd linux-setup
./backup.sh myname        # saves everything into profiles/myname
git diff                  # check it, especially the dotfiles
git add -A && git commit -m "backup" && git push
```

On the fresh install:

```bash
sudo apt install -y git
git clone https://github.com/AndreMel-30/linux-setup.git ~/linux-setup
cd ~/linux-setup && ./install.sh myname
```

Then reboot. At the end, `install.sh` lists anything it could not do. You can run it again as many times as you like.

If you leave out the name, the profile is called `default`.

## Profiles

A profile is just a folder. Its name is whatever you type after the script name; it is not taken from your username or your computer.

```
profiles/myname/
├── setup.conf      what to do (see below)
├── packages/       apt.txt, flatpak.txt, snap.txt, one entry per line
├── dconf/          desktop settings, one .ini file per dconf branch
├── dotfiles/       copies of your config files
└── hooks/          your own scripts
```

`profiles/example/` is the starting point. The first time you run `backup.sh` with a new name, it creates the folder and copies `setup.conf` from the example. After that, `setup.conf` is yours to edit. The scripts read it but never change it.

### setup.conf

This is where you decide what the scripts do. It is a normal bash file with a few variables:

| Variable | What it does |
|---|---|
| `DO_APT`, `DO_FLATPAK`, `DO_SNAP` | Turn each package manager on or off. Set `DO_SNAP=false` on Mint, which has snap disabled. |
| `DO_DCONF`, `DO_DOTFILES`, `DO_HOOKS` | Same idea for desktop settings, dotfiles and hooks. |
| `SWAPPINESS` | How eagerly the kernel uses swap. Ubuntu and Mint use 60; lower values keep more in RAM. Leave empty to skip. |
| `ENABLE_TRIM` | Turn on the weekly TRIM timer for SSDs. |
| `DOTFILES` | Which files or folders in your home folder to save. |
| `DCONF_PATHS` | Which dconf branches to save. Empty means it picks them from your desktop. |

## What the scripts do

### backup.sh

It reads your system and writes the result into the profile. It does not change anything on the system itself.

- **apt**: lists the packages you installed by hand. It subtracts the list from the moment the system was installed, so you only get your own packages and not the hundreds that came with the distro.
- **Flatpak and Snap**: lists the apps you have installed.
- **dconf**: dumps the desktop settings to text files.
- **dotfiles**: copies the files listed in `DOTFILES`, and warns you if one looks like it contains a token or password.

### install.sh

It reads the profile and applies it to the new system. Run it as a normal user, not with `sudo`; it asks for your password once.

1. Runs `hooks/pre-*.sh`
2. Updates the system
3. Installs the apt, Flatpak and Snap packages. A package that can't be found is skipped and reported, it doesn't stop the rest.
4. Sets swappiness and TRIM
5. Loads the dconf settings
6. Links the dotfiles into your home folder. They are symlinks, so editing `~/.bashrc` edits the file in the repo. If a file is already there, it is renamed to `.bak.<date>`, never deleted. Because of the links, keep the repo in a fixed place (like `~/linux-setup`): if you move or delete it, those files stop working.
7. Runs `hooks/post-*.sh`

### lib/

`lib/common.sh` has the small functions both scripts share.

## Hooks

For things that aren't a normal package: a `pre-*.sh` script runs before the packages (good for adding a PPA or repository), a `post-*.sh` script runs at the end (good for tools with their own installer, like Tailscale). There are two examples in `profiles/example/hooks/`.

`backup.sh` also writes `packages/apt-sources.txt`, a list of the third-party repositories you use now. It is only a reminder; it is not restored automatically.

## Good to know

- Try it in a virtual machine first. `backup.sh` is safe to run any time, but `install.sh` changes the system.
- Other desktops (KDE, XFCE...) are not recognised for dconf. You can still save their config folders by adding them to `DOTFILES`, for example `.config/xfce4`.
- Distros that are not Ubuntu-based are refused. `FORCE=1 ./install.sh myname` lets you try anyway.
- If you keep your profile in a public repo, read your dotfiles first. A private repo is safer. A profile can also live outside this folder: any argument with a `/` is used as a path, for example `./install.sh ~/my-profile`.

## License

MIT

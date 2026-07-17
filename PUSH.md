# Cómo subirlo a GitHub (2 minutos)

## 1. Crea el repo vacío en GitHub
Ve a https://github.com/new
- Repository name: `latenciatools`
- Description: `Fedora-native security toolkit installer — Kali's arsenal, done the Fedora way.`
- Public
- NO marques "Add a README", "Add .gitignore" ni "Choose a license" (ya los traemos)

## 2. Desde esta carpeta, inicializa y sube
```bash
cd /tmp/latenciatools-repo        # o donde tengas estos archivos
git init
git add .
git commit -m "LatenciaTools v2.1.3-beta — Fedora-native security toolkit installer"
git branch -M main
git remote add origin git@github.com:<TU_USUARIO>/latenciatools.git   # o https://github.com/<TU_USUARIO>/latenciatools.git
git push -u origin main
```

## 3. Tag de la release (opcional pero recomendado)
```bash
git tag -a v2.1.3-beta -m "First public beta — verified on Fedora 44, July 2026"
git push origin v2.1.3-beta
```
Luego en GitHub: Releases → Draft a new release → elige el tag → título "v2.1.3-beta" → publica.

## Después del push
- Añade topics al repo: `fedora`, `pentesting`, `security-tools`, `bash`, `installer`, `kali-alternative`
- (Opcional) activa Discussions para feedback de la comunidad

# more-go.nvim
some go utils

## 📦 Installation

### [lazy.nvim](https://github.com/folke/lazy.nvim)

```lua
	{
		"edte/more-go.nvim",
		ft = "go",
		opts = {},
	},
```


## 📝 Configuration

### blink
```lua
    sources = {
      default = {
        ...
        "go_pkgs",
      },
      providers = {
        go_pkgs = {
          name = "Module",
          module = "more-go.go-pkgs-blink",
        }
      }
    }
```

### cmp
```lua
sources = {
    ...
    {
        name = "go_pkgs",
        priority = 7,
    }
}

```


## 🚀 Usage

### go package import
![import](https://github.com/user-attachments/assets/0a38919e-fdcc-4513-88bc-fd1a189e1c33)

### Implement show
![Implement](https://github.com/user-attachments/assets/4e506953-5e41-4340-a810-93597e5bbe1a)

### return values auto add
https://github.com/user-attachments/assets/47880dbc-1e54-4fb9-9efe-36d2ef156ca1

### implement interface
https://github.com/user-attachments/assets/73a43c08-cbf7-45f6-9a78-96157eec6c88

## 📄 Thanks
- [impl.nvim](https://github.com/jack-rabe/impl.nvim)
- [go-impl.nvim](https://github.com/fang2hou/go-impl.nvim)
- [auto-fix-return.nvim](https://github.com/Jay-Madden/auto-fix-return.nvim)
- [goplements.nvim](https://github.com/maxandron/goplements.nvim/)
- [cmp-go-pkgs](https://github.com/Snikimonkd/cmp-go-pkgs)

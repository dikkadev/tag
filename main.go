package main

// // go:generate go-winres make

import (
	"context"
	"log"
	"strings"
	"time"

	"github.com/go-vgo/robotgo"
	"github.com/lxn/walk"
	. "github.com/lxn/walk/declarative"
)

var mainWindow *walk.MainWindow
var btn *walk.PushButton
var ctx context.Context
var cancel context.CancelFunc

type Tag struct {
	Tag string
}

func main() {
	tag := new(Tag)
	escAction := Action{
		Text: "Close",
		Shortcut: Shortcut{
			Key: walk.KeyEscape,
		},
	}
	ctrlCAction := Action{
		Text: "Close",
		Shortcut: Shortcut{
			Key:       walk.KeyC,
			Modifiers: walk.ModControl,
		},
	}
	_ = escAction
	_ = ctrlCAction

	var db *walk.DataBinder

	ctx, cancel = context.WithCancel(context.Background())
	size := Size{Width: 200, Height: 100}
	if _, err := (MainWindow{
		AssignTo: &mainWindow,
		Title:    "Tag",
		Size:     size,
		MaxSize:  size,
		MinSize:  size,
		Layout:   VBox{},
		DataBinder: DataBinder{
			AssignTo:       &db,
			Name:           "tag",
			DataSource:     tag,
			ErrorPresenter: ToolTipErrorPresenter{},
		},
		Children: []Widget{
			LineEdit{
				Text: Bind("Tag"),
				OnKeyPress: func(key walk.Key) {
					if key == walk.KeyReturn {
						err := db.Submit()
						if err != nil {
							panic(err)
						}
						mainWindow.Close()
						time.Sleep(100 * time.Millisecond)
						typeOutTag(tag.Tag)
						cancel()
					}
					if key == walk.KeyEscape {
						mainWindow.Close()
						cancel()
					}
				},
			},
		},
	}.Run()); err != nil {
		log.Fatal(err)
	}
}

func typeOutTag(tag string) {
	delay := 80 * time.Millisecond
	tag = strings.ReplaceAll(tag, " ", "_")

	// Type the opening tag
	robotgo.TypeStr("<" + tag + ">")
	time.Sleep(delay)

	// Shift+Enter for new line within the tag structure
	robotgo.KeyTap("enter", "shift")
	time.Sleep(delay)

	// Another Shift+Enter for space for closing tag
	robotgo.KeyTap("enter", "shift")
	robotgo.TypeStr("</" + tag + ">")
	time.Sleep(delay)

	// Move up one line to adjust cursor position
	robotgo.KeyTap("up")
}

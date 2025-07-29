using Microsoft.AspNetCore.Mvc;
using Microsoft.EntityFrameworkCore;
using IronXpress.DTOs;

namespace IronXpress.Models;

[ApiController]
[Route("api/[controller]")]
public class AuthController : ControllerBase
{
    private readonly AppDbContext _context;

    public AuthController(AppDbContext context) => _context = context;

    [HttpPost("login")]
    public async Task<IActionResult> Login([FromBody] LoginRequest request)
    {
        var user = await _context.Users.SingleOrDefaultAsync(u => u.Mobile == request.Mobile);
        if (user == null || !BCrypt.Net.BCrypt.Verify(request.Password, user.PasswordHash))
            return Unauthorized(new { message = "Invalid mobile or password" });

        return Ok(new { user.Id, user.Name, user.Mobile });
    }

}

